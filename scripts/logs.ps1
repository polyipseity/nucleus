<#
.SYNOPSIS
  Append-only JSONL event logs plus rotation and expiry over the managed log
  roots.

.DESCRIPTION
  The Windows half of nucleus-logs. It owns the same operations as
  scripts/logs.sh: append one canonical event line per invocation, show, tail,
  label, stats, rotate, expire, and gc. Rotation is implemented here, because
  nucleus-logs is the one owner of rotation on either platform; expiry delegates
  to the shared Invoke-LogManagement.ps1 implementation.

  One event per line. Each line is a JSON object with the keys ts, id, kind,
  harness, decision, source, filter, rule, latency_ms, summary, digest; absent
  keys are written as null, so every line carries the full key set.

.PARAMETER Action
  Subcommand: append, expire, gc, label, rotate, show, stats, or tail.

.PARAMETER Log
  Log name for append, show, stats, and tail; label uses it as the target log instead of the harness default.

.PARAMETER Id
  label: event id the verdict applies to.

.PARAMETER Verdict
  label: the verdict, one of correct, false-allow, or false-deny.

.PARAMETER Note
  label: free-text justification stored as the event's note field.

.PARAMETER Since
  show: keep events at or after an ISO-8601 timestamp.

.PARAMETER Kind
  show: keep events whose kind matches.

.PARAMETER Harness
  show: keep events whose harness matches.

.PARAMETER Lines
  tail: number of events to print (default: 10).

.PARAMETER Scope
  Log root to operate on: user or system (default: user). Every subcommand but
  label takes it; label always appends to the user root.

.PARAMETER MaxSize
  rotate: size in bytes that triggers rotation (default: services schema).

.PARAMETER MaxFiles
  rotate: number of archives to keep (default: services schema).

.PARAMETER Compress
  rotate: gzip rotated archives (default: services schema).

.PARAMETER Expiry
  expire: archive retention, e.g. 7d (default: NUCLEUS_LOG_EXPIRY or 7d).

.PARAMETER Json
  Emit one JSON document instead of text.

.PARAMETER DryRun
  Report what would change without writing.

.PARAMETER Help
  Print this help and exit 0.

.EXAMPLE
  '{"id":"abc","kind":"decision"}' | pwsh -File scripts/logs.ps1 append -Log decisions

.EXAMPLE
  pwsh -File scripts/logs.ps1 show -Log decisions -Json

.NOTES
  Environment variables: NUCLEUS_REPO_ROOT (log root resolution),
  NUCLEUS_LOG_DIR and NUCLEUS_SYSTEM_LOG_DIR (path overrides),
  NUCLEUS_LOG_EXPIRY (archive retention).
  Exit codes: 0 on success; 1 on a usage or write error.
#>

[CmdletBinding()]
param(
  [Parameter(Position = 0)]
  [ValidateSet('append', 'expire', 'gc', 'label', 'rotate', 'show', 'stats', 'tail')]
  [string]$Action,
  [Parameter(Position = 1)]
  [Alias('LogName')]
  [string]$Log,
  [string]$Id,
  [string]$Verdict,
  [string]$Note,
  [string]$Since,
  [string]$Kind,
  [string]$Harness,
  [int]$Lines = 10,
  [ValidateSet('user', 'system')]
  [string]$Scope = 'user',
  [string]$MaxSize,
  [string]$MaxFiles,
  [string]$Compress,
  [string]$Expiry,
  [switch]$Json,
  [switch]$DryRun,
  [switch]$Help
)

# WHY: only the entry script changes its own session. A dot-sourcing caller
# loads the functions and keeps its strict mode, its error preference, and its
# own environment validity; the CLI dispatch and the environment checks below
# are entry-script work.
$script:IsEntryScript = $MyInvocation.InvocationName -ne '.'
if ($script:IsEntryScript) {
  Set-StrictMode -Version Latest
  $ErrorActionPreference = 'Stop'
}

# WHY the import stays unconditional: the writer's helpers come from this module
# and the log-management module below, so the dot-source contract depends on
# them being present.
$modulePath = Join-Path $PSScriptRoot '..\src\platforms\Windows\modules\Format-NucleusOutput.psm1'
Import-Module $modulePath -Force -DisableNameChecking

# WHY 4096: one bounded write of at most a page reaches the file as a single
# operation, so concurrent appenders never interleave inside a line. The limit
# budgets the trailing newline, so an event is refused once line plus newline
# reaches the size; it is never truncated, because a truncated event is
# unparseable history.
$script:MaxEventBytes = 4096

# Labels are ordinary events appended to the harness log, so a verdict never
# rewrites the line it annotates. Gate decisions live in that log, which is why
# it is the default.
$script:LabelLog = 'harness'

# The verdict vocabulary the gate review reads back.
$script:LabelVerdicts = @('correct', 'false-allow', 'false-deny')

$script:EventKeys = @(
  'ts', 'id', 'kind', 'harness', 'decision',
  'source', 'filter', 'rule', 'latency_ms', 'summary', 'digest'
)

$repoRoot = $env:NUCLEUS_REPO_ROOT
if ($script:IsEntryScript -and [string]::IsNullOrWhiteSpace($repoRoot) -and [string]::IsNullOrWhiteSpace($env:NUCLEUS_LOG_DIR)) {
  Write-NucleusError -CommandName logs 'NUCLEUS_REPO_ROOT not set'
  exit 1
}

$moduleDir = if ($repoRoot) { Join-Path -Path $repoRoot -ChildPath 'src\platforms\Windows\modules' } else { $null }
if ($moduleDir -and (Test-Path -LiteralPath (Join-Path -Path $moduleDir -ChildPath 'Invoke-LogManagement.ps1'))) {
  . (Join-Path -Path $moduleDir -ChildPath 'Invoke-LogManagement.ps1')
} elseif ($script:IsEntryScript) {
  Write-NucleusError -CommandName logs "Invoke-LogManagement.ps1 not found under '$moduleDir'"
  exit 1
}

function Get-LogsDir {
  <#
  .SYNOPSIS
    Returns the managed log root for a scope.
  .PARAMETER ScopeName
    user or system.
  #>
  param([string]$ScopeName)

  if ($ScopeName -eq 'system') { return Get-NucleusSystemLogDir }
  return Get-NucleusLogDir
}

function ConvertTo-LogEventLine {
  <#
  .SYNOPSIS
    Normalizes one event into the canonical sorted-key JSON line.
  .DESCRIPTION
    Stamps ts when absent and fills every missing canonical key with null, so
    every line carries the same key set. Extra keys are kept and sorted with the
    rest.
  .PARAMETER LogEvent
    Event fields as a hashtable.
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param(
    [Parameter(Mandatory)]
    [hashtable]$LogEvent
  )

  $normalized = @{}
  foreach ($key in $script:EventKeys) {
    $normalized[$key] = $null
  }
  $normalized['ts'] = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
  foreach ($entry in $LogEvent.GetEnumerator()) {
    $normalized[$entry.Key] = $entry.Value
  }

  # WHY sorted: the committed JSON contract is byte-stable, and ConvertTo-Json
  # emits a hashtable in its own order.
  $sorted = [ordered]@{}
  foreach ($key in ($normalized.Keys | Sort-Object -CaseSensitive)) {
    $sorted[$key] = $normalized[$key]
  }
  return ($sorted | ConvertTo-Json -Compress -Depth 5)
}

function Add-NucleusLogEvent {
  <#
  .SYNOPSIS
    Appends one canonical event line to a log.
  .DESCRIPTION
    The single writer every caller shares. An exclusive <log>.lock sidecar is
    held for the duration of one append, which serializes app writers, while the
    log itself is opened shared so a native writer redirecting into it is never
    blocked. The sidecar is removed before the append returns, so it never
    outlives the write it guarded.
  .PARAMETER LogName
    Log name, written to <log root>\<LogName>.log. Alias: -Log.
  .PARAMETER LogEvent
    Event fields as a hashtable; missing canonical keys become null. Alias: -Event.
  .PARAMETER Directory
    Log root; defaults to the user log root.
  #>
  [CmdletBinding(SupportsShouldProcess)]
  param(
    [Parameter(Mandatory)]
    [Alias('Log')]
    [string]$LogName,
    [Parameter(Mandatory)]
    [Alias('Event')]
    [hashtable]$LogEvent,
    [string]$Directory
  )

  # WHY the name is checked first: no path may be derived from an empty or
  # whitespace-only name, so the directory lookup and every FileStream below are
  # reached only with a usable name.
  if ([string]::IsNullOrWhiteSpace($LogName)) {
    throw 'log name must not be empty'
  }
  if ($LogName -notmatch '^[A-Za-z0-9._-]+$') {
    throw "invalid log name '$LogName' (allowed: A-Z a-z 0-9 . _ -)"
  }
  if (-not $Directory) { $Directory = Get-LogsDir -ScopeName 'user' }
  if ([string]::IsNullOrWhiteSpace($Directory)) {
    throw 'no log directory resolved; set NUCLEUS_LOG_DIR or NUCLEUS_REPO_ROOT before appending'
  }

  $line = ConvertTo-LogEventLine -LogEvent $LogEvent
  $bytes = [System.Text.Encoding]::UTF8.GetByteCount($line)
  if ($bytes + 1 -ge $script:MaxEventBytes) {
    throw "event is $bytes bytes; a line plus its newline must stay under $($script:MaxEventBytes)"
  }

  $path = Join-Path -Path $Directory -ChildPath "$LogName.log"
  if ([string]::IsNullOrWhiteSpace($path)) {
    throw "no log path resolved for '$LogName' under '$Directory'"
  }
  if (-not (Test-Path -LiteralPath $Directory -PathType Container)) {
    $null = New-Item -Path $Directory -ItemType Directory -Force  # check-suppress:suppression_doc: New-Item returns the created directory item, which the caller already knows from $Directory, so the object is discarded
  }
  if (-not $PSCmdlet.ShouldProcess($path, "Append $bytes byte event")) {
    Write-NucleusDryRun -CommandName logs "would append $bytes bytes to '$path'"
    Write-Output $line
    return
  }

  $payload = [System.Text.Encoding]::UTF8.GetBytes($line + [Environment]::NewLine)
  # WHY a lock sidecar: FileMode.Append seeks to the end and writes, so two app
  # writers sharing the log would overwrite the line in flight. An exclusive
  # .lock file serializes them, while the log itself stays shared so a service
  # redirecting stdout into it keeps working.
  # WHY the sidecar is removed while it is still held: it must not outlive the
  # append, and a delete after the close lets a waiting appender take the old file
  # while another creates a new one, so two appenders write at once and lose an
  # event. Holding it through the delete keeps every waiter out until its next
  # attempt creates the single new file.
  # WHY the share mode differs per platform: on Unix only FileShare.None takes the
  # exclusive lock the sidecar depends on, and unlink ignores the share mode, so
  # None both excludes and allows the removal. On Windows that same value forbids
  # the delete, while FileShare.Delete still refuses another appender's read/write
  # open and holds the removal pending until the handle closes.
  $lockShare = if ($IsWindows) { [System.IO.FileShare]::Delete } else { [System.IO.FileShare]::None }
  $lockPath = "$path.lock"
  $lockAttempts = 0
  while ($true) {
    try {
      $lock = [System.IO.FileStream]::new(
        $lockPath,
        [System.IO.FileMode]::OpenOrCreate,
        [System.IO.FileAccess]::ReadWrite,
        $lockShare)
      break
    } catch [System.IO.IOException] {
      $lockAttempts++
      if ($lockAttempts -ge 500) {
        throw "timed out after $lockAttempts attempts waiting for '$lockPath'"
      }
      Start-Sleep -Milliseconds 10
    }
  }

  try {
    $stream = [System.IO.FileStream]::new(
      $path,
      [System.IO.FileMode]::Append,
      [System.IO.FileAccess]::Write,
      [System.IO.FileShare]::ReadWrite)
    try {
      $stream.Write($payload, 0, $payload.Length)
      $stream.Flush()
    } finally {
      $stream.Dispose()
    }
  } finally {
    # WHY the delete comes before the close, and why it runs on the failed-write
    # path too: see the share-mode comment at the acquisition. A throw here
    # still closes the handle, so an unwritable sidecar fails the append instead of
    # leaking it.
    try {
      [System.IO.File]::Delete($lockPath)
    } finally {
      $lock.Dispose()
    }
  }
}

function Get-LogArchiveIndex {
  <#
  .SYNOPSIS
    Returns the rotation index of an archive name, or $null when it is not one.
  .DESCRIPTION
    Windows rotation names archives <base>.<N>.log.gz, the POSIX rotation names
    them <log>.log.<N>.gz, and a reader has to see both so rotated history stays
    visible whichever writer produced it.
  .PARAMETER Name
    File name to test.
  .PARAMETER LogName
    Log the archive must belong to.
  #>
  [OutputType([int])]
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [string]$Name,
    [Parameter(Mandatory)]
    [string]$LogName
  )

  $escaped = [regex]::Escape($LogName)
  foreach ($pattern in @("^$escaped\.(\d+)\.log(\.gz)?$", "^$escaped\.log\.(\d+)(\.gz)?$")) {
    if ($Name -match $pattern) { return [int]$Matches[1] }
  }
  return $null
}

function Get-LogEventStream {
  <#
  .SYNOPSIS
    Returns the JSONL lines of one log, archives oldest first.
  .PARAMETER Directory
    Log root.
  .PARAMETER LogName
    Log name.
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param(
    [Parameter(Mandatory)]
    [string]$Directory,
    [Parameter(Mandatory)]
    [string]$LogName
  )

  $archives = @()
  if (Test-Path -LiteralPath $Directory -PathType Container) {
    # check-suppress:suppression_doc: probe -- no archives may exist yet; the empty result is handled below.
    $archives = @(Get-ChildItem -LiteralPath $Directory -File -ErrorAction SilentlyContinue |
        Where-Object { $null -ne (Get-LogArchiveIndex -Name $_.Name -LogName $LogName) })
  }
  $ordered = $archives | Sort-Object -Property {
    # WHY: the numeric suffix is the archive age, and a plain name sort would
    # order .10 before .9 once ten archives exist.
    Get-LogArchiveIndex -Name $_.Name -LogName $LogName
  } -Descending

  foreach ($archive in $ordered) {
    # WHY the branch: rotation leaves <base>.N.log as plain text when compression
    # is off, and feeding that to GZipStream throws InvalidDataException.
    if ($archive.Name -like '*.gz') {
      $inputStream = [System.IO.File]::OpenRead($archive.FullName)
      try {
        $gzip = [System.IO.Compression.GZipStream]::new($inputStream, [System.IO.Compression.CompressionMode]::Decompress)
        try {
          $reader = [System.IO.StreamReader]::new($gzip)
          try {
            $reader.ReadToEnd() -split "`n" | Where-Object { $_ }
          } finally {
            $reader.Dispose()
          }
        } finally {
          $gzip.Dispose()
        }
      } finally {
        $inputStream.Dispose()
      }
    } else {
      Get-Content -LiteralPath $archive.FullName
    }
  }

  $live = Join-Path -Path $Directory -ChildPath "$LogName.log"
  if (Test-Path -LiteralPath $live -PathType Leaf) {
    Get-Content -LiteralPath $live
  }
}

function Format-LogEventLine {
  <#
  .SYNOPSIS
    Renders one event object as a text line.
  .PARAMETER LogEvent
    Parsed event object.
  #>
  param([Parameter(Mandatory)] [pscustomobject]$LogEvent)

  $fields = @()
  foreach ($name in @('ts', 'kind', 'id', 'decision', 'summary')) {
    $property = $LogEvent.PSObject.Properties[$name]
    if ($null -eq $property -or $null -eq $property.Value) {
      $fields += '-'
    } elseif ($property.Value -is [datetime]) {
      # WHY: ConvertFrom-Json turns an ISO-8601 string into a DateTime, and the
      # text view must show the stored timestamp, not the host's locale format.
      $fields += $property.Value.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    } else {
      $fields += [string]$property.Value
    }
  }
  return ($fields -join "`t")
}

function Select-LogEvent {
  <#
  .SYNOPSIS
    Returns the events of a log that match the given filters.
  .PARAMETER Directory
    Log root.
  .PARAMETER LogName
    Log name.
  .PARAMETER SinceFilter
    Keep events at or after this ISO-8601 timestamp.
  .PARAMETER KindFilter
    Keep events whose kind matches.
  .PARAMETER HarnessFilter
    Keep events whose harness matches.
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [string]$Directory,
    [Parameter(Mandatory)]
    [string]$LogName,
    [string]$SinceFilter,
    [string]$KindFilter,
    [string]$HarnessFilter
  )

  foreach ($line in (Get-LogEventStream -Directory $Directory -LogName $LogName)) {
    $logEvent = $null
    try {
      $logEvent = $line | ConvertFrom-Json -ErrorAction Stop
    } catch {
      continue
    }
    if ($logEvent -isnot [pscustomobject]) { continue }
    if ($SinceFilter) {
      $tsProperty = $logEvent.PSObject.Properties['ts']
      $ts = if ($null -ne $tsProperty) { $tsProperty.Value } else { '' }
      if (-not $ts -or $ts -lt $SinceFilter) { continue }
    }
    if ($KindFilter) {
      $kindProperty = $logEvent.PSObject.Properties['kind']
      if ($null -eq $kindProperty -or $kindProperty.Value -ne $KindFilter) { continue }
    }
    if ($HarnessFilter) {
      $harnessProperty = $logEvent.PSObject.Properties['harness']
      if ($null -eq $harnessProperty -or $harnessProperty.Value -ne $HarnessFilter) { continue }
    }
    $logEvent
  }
}

function Get-LogStatReport {
  <#
  .SYNOPSIS
    Returns per-log counters for one log root.
  .PARAMETER Directory
    Log root.
  .PARAMETER LogFilter
    Restrict the result to one log name.
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [string]$Directory,
    [string]$LogFilter
  )

  if (-not (Test-Path -LiteralPath $Directory -PathType Container)) { return }

  # WHY the exclusion: an uncompressed archive is named <base>.N.log and matches
  # *.log, but it is rotated history rather than a log of its own.
  # check-suppress:suppression_doc: probe -- an empty log root is reported as no rows, not as an error.
  $files = @(Get-ChildItem -LiteralPath $Directory -Filter '*.log' -File -ErrorAction SilentlyContinue |
      Where-Object { $_.Name -notmatch '\.\d+\.log(\.gz)?$' -and $_.Name -notmatch '\.log\.\d+(\.gz)?$' })
  foreach ($file in $files) {
    $name = $file.BaseName
    if ($LogFilter -and $name -ne $LogFilter) { continue }
    $lines = @(Get-Content -LiteralPath $file.FullName)
    $last = if ($lines.Count -gt 0) {
      try { ($lines[-1] | ConvertFrom-Json -ErrorAction Stop).ts } catch { $null }
    } else { $null }
    # check-suppress:suppression_doc: probe -- a log with no archives reports zero.
    $archives = @(Get-ChildItem -LiteralPath $Directory -File -ErrorAction SilentlyContinue |
        Where-Object { $null -ne (Get-LogArchiveIndex -Name $_.Name -LogName $name) }).Count
    [pscustomobject]@{
      log      = $name
      events   = $lines.Count
      bytes    = $file.Length
      archives = $archives
      last_ts  = $last
    }
  }
}

function Get-LogsSchemaDefault {
  <#
  .SYNOPSIS
    Returns the services.schema.json default for a rotation knob.
  .PARAMETER Field
    maxSize, maxFiles, or compress.
  .PARAMETER Fallback
    Value used when the schema cannot be read.
  #>
  [OutputType([string])]
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [string]$Field,
    [Parameter(Mandatory)]
    [string]$Fallback
  )

  if (-not $repoRoot) {
    Write-NucleusWarning -CommandName logs 'repo root unresolvable; using the built-in default'
    return $Fallback
  }
  $schemaPath = Join-Path -Path $repoRoot -ChildPath 'src\modules\services.schema.json'
  if (-not (Test-Path -LiteralPath $schemaPath -PathType Leaf)) {
    Write-NucleusWarning -CommandName logs "services.schema.json not found; using the built-in $Field default $Fallback"
    return $Fallback
  }
  $schema = Get-Content -LiteralPath $schemaPath -Raw | ConvertFrom-Json
  $properties = $schema.definitions.loggingEntry.properties
  $property = $properties.PSObject.Properties[$Field]
  if ($null -eq $property -or $null -eq $property.Value.default) {
    Write-NucleusWarning -CommandName logs "services.schema.json has no $Field default; using the built-in default $Fallback"
    return $Fallback
  }
  return [string]$property.Value.default
}

function Invoke-LogRotation {
  <#
  .SYNOPSIS
    Rotates the log files under a root by size, with copy-truncate.
  .DESCRIPTION
    Recursively scans for *.log files and rotates each one over MaxSize with
    copy-truncate, so a service holding its log open keeps writing into the same
    file. Archives shift .1 through MaxFiles and the oldest is dropped.
    An archive is skipped: rotation names its own output <base>.N.log, which
    matches *.log, and rotating that again files history under a name no reader
    looks for. That exclusion is name-shaped, so a live log whose own name ends in
    .<digits>.log is skipped as well.
  .PARAMETER Path
    Root directory containing log files to rotate.
  .PARAMETER MaxSize
    Maximum file size in bytes before rotation (default: 10 MB).
  .PARAMETER MaxFiles
    Number of rotated archives to keep (default: 4).
  .PARAMETER Compress
    Whether to compress rotated archives with gzip (default: $true).
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [string]$Path,
    [int]$MaxSize = 10000000, # bytes
    [int]$MaxFiles = 4,
    [bool]$Compress = $true
  )

  if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return }

  # check-suppress:suppression_doc: probe -- no log files may exist; empty result handled.
  $logFiles = Get-ChildItem -LiteralPath $Path -Recurse -Filter '*.log' -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -notmatch '\.\d+\.log(\.gz)?$' }
  foreach ($file in $logFiles) {
    if ($file.Length -le $MaxSize) { continue }

    $isWritable = $false
    try {
      $writeStream = [System.IO.File]::OpenWrite($file.FullName)
      $writeStream.Close()
      $isWritable = $true
    } catch {
      $isWritable = $false
    }
    if (-not $isWritable) {
      throw "log rotation requires write access to '$($file.FullName)'; run as administrator"
    }

    $baseName = $file.BaseName
    $dir = $file.DirectoryName

    # drop the oldest archive when at max
    $oldest = $MaxFiles
    $oldestPath = Join-Path -Path $dir -ChildPath "$baseName.$oldest.log"
    if (Test-Path -LiteralPath $oldestPath -PathType Leaf) {
      Remove-Item -LiteralPath $oldestPath -Force
    }
    if ($Compress) {
      $oldestGz = "$oldestPath.gz"
      if (Test-Path -LiteralPath $oldestGz -PathType Leaf) {
        Remove-Item -LiteralPath $oldestGz -Force
      }
    }

    # shift N -> N+1
    for ($i = $MaxFiles - 1; $i -ge 1; $i--) {
      $src = Join-Path -Path $dir -ChildPath "$baseName.$i.log"
      $dst = Join-Path -Path $dir -ChildPath "$baseName.$($i + 1).log"
      if (Test-Path -LiteralPath $src -PathType Leaf) {
        Move-Item -LiteralPath $src -Destination $dst -Force
      }
      if ($Compress) {
        $srcGz = "$src.gz"
        $dstGz = "$dst.gz"
        if (Test-Path -LiteralPath $srcGz -PathType Leaf) {
          Move-Item -LiteralPath $srcGz -Destination $dstGz -Force
        }
      }
    }

    # copy-truncate keeps the inode
    $archivePath = Join-Path -Path $dir -ChildPath "$baseName.1.log"
    Copy-Item -LiteralPath $file.FullName -Destination $archivePath -Force
    $truncateStream = [System.IO.File]::Open(
      $file.FullName,
      [System.IO.FileMode]::Open,
      [System.IO.FileAccess]::Write
    )
    $truncateStream.SetLength(0)
    $truncateStream.Close()

    if ($Compress) {
      $null = & gzip @($archivePath) 2>$null  # check-suppress:suppression_doc: archive may fail to compress if already corrupted or missing; $? checked below
      if (-not $?) {
        Write-NucleusWarning -CommandName log-rotation "gzip failed for $archivePath; keeping uncompressed."
      }
    }
  }
}

# WHY: only the entry script dispatches. A caller that dot-sources this file
# imports Add-NucleusLogEvent without printing help and exiting 1.
if (-not $script:IsEntryScript) { return }

if ($Help -or [string]::IsNullOrWhiteSpace($Action)) {
  Get-Help -Full $PSCommandPath
  if ($Help) { exit 0 }
  Write-NucleusError -CommandName logs 'missing action (append, expire, gc, label, rotate, show, stats, tail)'
  exit 1
}

$logDir = Get-LogsDir -ScopeName $Scope
$userLogDir = Get-LogsDir -ScopeName 'user'

switch ($Action) {
  'append' {
    if (-not $Log) {
      Write-NucleusError -CommandName logs 'append requires -Log'
      exit 1
    }
    $raw = [Console]::In.ReadLine()
    if ([string]::IsNullOrWhiteSpace($raw)) {
      Write-NucleusError -CommandName logs 'expected one JSON event object on stdin'
      exit 1
    }
    # WHY refuse a second line: scripts/logs.sh dies on the same input, because a
    # caller that piped two events would otherwise see one appended and the other
    # dropped without a word.
    if ($null -ne [Console]::In.ReadLine()) {
      Write-NucleusError -CommandName logs 'expected exactly one event line on stdin'
      exit 1
    }
    $parsed = $raw | ConvertFrom-Json
    if ($parsed -isnot [pscustomobject]) {
      Write-NucleusError -CommandName logs 'event is not a JSON object'
      exit 1
    }
    $logEvent = @{}
    foreach ($property in $parsed.PSObject.Properties) {
      $logEvent[$property.Name] = $property.Value
    }
    Add-NucleusLogEvent -LogName $Log -LogEvent $logEvent -Directory $logDir -WhatIf:$DryRun
  }
  'label' {
    # WHY reject the bound parameter: label always appends to the user root, so a
    # -Scope here names a destination the event never reaches and reads as
    # consent it never had. scripts/logs.sh has no --scope on label either.
    if ($PSBoundParameters.ContainsKey('Scope')) {
      Write-NucleusError -CommandName logs "unsupported option '-Scope' for label"
      exit 1
    }
    if (-not $Id -or -not $Verdict) {
      Write-NucleusError -CommandName logs 'label requires -Id and -Verdict'
      exit 1
    }
    if ($script:LabelVerdicts -notcontains $Verdict) {
      Write-NucleusError -CommandName logs "invalid verdict '$Verdict' (expected: $($script:LabelVerdicts -join ', '))"
      exit 1
    }
    $labelLog = if ($Log) { $Log } else { $script:LabelLog }
    # WHY null: POSIX writes null when --note is absent, and "" would be a
    # different JSON value for the same absence.
    $logEvent = @{ kind = 'label'; id = $Id; verdict = $Verdict; note = $(if ($Note) { $Note } else { $null }); source = 'none' }
    Add-NucleusLogEvent -LogName $labelLog -LogEvent $logEvent -Directory $userLogDir -WhatIf:$DryRun
  }
  'show' {
    if (-not $Log) {
      Write-NucleusError -CommandName logs 'show requires -Log'
      exit 1
    }
    $events = @(Select-LogEvent -Directory $logDir -LogName $Log -SinceFilter $Since -KindFilter $Kind -HarnessFilter $Harness)
    if ($Json) {
      ConvertTo-Json -InputObject $events -Depth 5
    } else {
      foreach ($logEvent in $events) { Format-LogEventLine -LogEvent $logEvent }
    }
  }
  'tail' {
    if (-not $Log) {
      Write-NucleusError -CommandName logs 'tail requires -Log'
      exit 1
    }
    $path = Join-Path -Path $logDir -ChildPath "$Log.log"
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
      Write-NucleusInfo -CommandName logs "no log '$Log' under '$logDir'"
      exit 0
    }
    foreach ($line in (Get-Content -LiteralPath $path -Tail $Lines)) {
      $logEvent = try { $line | ConvertFrom-Json -ErrorAction Stop } catch { continue }
      # WHY the format call sits outside the try: a malformed line is skippable, a
      # binding error in the formatter is not, and swallowing it made tail print
      # nothing and exit 0.
      Format-LogEventLine -LogEvent $logEvent
    }
  }
  'stats' {
    $rows = @(Get-LogStatReport -Directory $logDir -LogFilter $Log)
    if ($Json) {
      ConvertTo-Json -InputObject $rows -Depth 5
    } elseif ($rows.Count -eq 0) {
      Write-NucleusInfo -CommandName logs "no logs under '$logDir'"
    } else {
      $rows | Format-Table -AutoSize | Out-String -Width 200
    }
  }
  'rotate' {
    $size = if ($MaxSize) { [int]$MaxSize } else { [int](Get-LogsSchemaDefault -Field 'maxSize' -Fallback '10000000') }
    $files = if ($MaxFiles) { [int]$MaxFiles } else { [int](Get-LogsSchemaDefault -Field 'maxFiles' -Fallback '4') }
    $compressValue = if ($Compress) { [bool]::Parse($Compress) } else { [bool]::Parse((Get-LogsSchemaDefault -Field 'compress' -Fallback 'true')) }
    if ($DryRun) {
      Write-NucleusDryRun -CommandName logs "would rotate logs in '$logDir' larger than $size bytes (keeping $files archives, compress=$compressValue)"
      exit 0
    }
    Invoke-LogRotation -Path $logDir -MaxSize $size -MaxFiles $files -Compress $compressValue
  }
  'expire' {
    $expiryValue = if ($Expiry) { $Expiry } elseif ($env:NUCLEUS_LOG_EXPIRY) { $env:NUCLEUS_LOG_EXPIRY } else { '7d' }
    if ($DryRun) {
      Write-NucleusDryRun -CommandName logs "would expire archives older than $expiryValue in '$logDir'"
      exit 0
    }
    Invoke-LogExpiry -Path $logDir -Expiry $expiryValue
  }
  'gc' {
    $size = if ($MaxSize) { [int]$MaxSize } else { [int](Get-LogsSchemaDefault -Field 'maxSize' -Fallback '10000000') }
    $files = if ($MaxFiles) { [int]$MaxFiles } else { [int](Get-LogsSchemaDefault -Field 'maxFiles' -Fallback '4') }
    $compressValue = if ($Compress) { [bool]::Parse($Compress) } else { [bool]::Parse((Get-LogsSchemaDefault -Field 'compress' -Fallback 'true')) }
    $expiryValue = if ($Expiry) { $Expiry } elseif ($env:NUCLEUS_LOG_EXPIRY) { $env:NUCLEUS_LOG_EXPIRY } else { '7d' }
    if ($DryRun) {
      Write-NucleusDryRun -CommandName logs "would rotate logs in '$logDir' larger than $size bytes (keeping $files archives, compress=$compressValue)"
      Write-NucleusDryRun -CommandName logs "would expire archives older than $expiryValue in '$logDir'"
      exit 0
    }
    Invoke-LogRotation -Path $logDir -MaxSize $size -MaxFiles $files -Compress $compressValue
    Invoke-LogExpiry -Path $logDir -Expiry $expiryValue
  }
}
