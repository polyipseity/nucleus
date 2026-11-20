<#
.SYNOPSIS
  Grouped nucleus user utilities.
.DESCRIPTION
  Subcommands:
  - optimize-pdf: optimize PDF files using Ghostscript with backup/restore.
  - strip-metadata: strip file metadata with mat2/exiftool. PDF and legacy OLE2
    files are skipped with a warning; inputs that could not be processed are
    listed at the end of the run.
  - harness-notify: normalize a harness lifecycle event into a Hermes notification.
  - harness-approval: request an approval decision for a harness tool call.
  - harness-filter: read a harness hook payload on stdin and print a decision document.
  - harness-drive: end a harness turn: notify and inject one queued remote prompt.
  - sandbox-context: detect the current sandbox state, compare it with the recorded
    state for the harness session, emit context on a change or first observation,
    and update the record.
  - safe-delete-guard: evaluate deletion commands against the safe-delete policy.
.PARAMETER Action
  The subcommand to run: optimize-pdf, strip-metadata, harness-notify,
  harness-approval, harness-filter, harness-drive, sandbox-context, safe-delete-guard.
.PARAMETER Preset
  Ghostscript PDF settings preset: default, ebook, prepress, printer, screen.
.PARAMETER Dialog
  Switch (strip-metadata only). Show one modal popup listing every input that was
  not processed. Needed by GUI callers: the context-menu verb runs with
  -WindowStyle Hidden, which discards stdout and stderr.
.PARAMETER Plain
  Switch (harness-approval only). Print the decision word alone instead of the
  harness's document.
.PARAMETER File
  One or more file paths to process, or positional arguments forwarded to
  harness, sandbox-context, and safe-delete-guard subcommands.
.NOTES
  Maps to the optimize-pdf --preset and --rm-bak and strip-metadata --rm-bak options.
  Harness and safe-delete-guard subcommands dispatch to implementations in
  src/scripts/notify/.
#>

[CmdletBinding()]
param(
  [Parameter(Position = 0)]
  [ValidateSet('optimize-pdf', 'strip-metadata', 'harness-notify', 'harness-approval', 'harness-filter', 'harness-drive', 'sandbox-context', 'safe-delete-guard')]
  [string]$Action,

  [Parameter()]
  [string]$Preset = "default",

  [Parameter()]
  [switch]$RemoveBackup,

  [Parameter()]
  [switch]$Dialog,

  [Parameter()]
  [switch]$Plain,

  [Parameter(Position = 1, ValueFromRemainingArguments)]
  [string[]]$File,

  [Alias("h")]
  [switch]$Help
)

. (Join-Path $PSScriptRoot '..\src\scripts\lib\pwsh-guard.ps1')
Assert-NucleusPowerShell -Minimum '7.0'

# check-suppress:suppression_doc: parameters are consumed via $PSBoundParameters in subcommand dispatch below
$null = $PSBoundParameters

$ErrorActionPreference = 'Stop'

function Show-NucleusNotification {
  # check-suppress:SuppressMessageAttribute: PSAvoidUsingEmptyCatchBlock -- notification is best-effort; all errors intentionally swallowed
  [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingEmptyCatchBlock', '')]
  param([string]$Title, [string]$Message)
  # check-suppress:suppression_doc: BurntToast module is optional: fall back to MessageBox.
  if (Get-Module -ListAvailable -Name BurntToast -ErrorAction SilentlyContinue) {
    try {
      New-BurntToastNotification -Text $Title, $Message -ErrorAction Stop
    } catch {
      # check-suppress:suppression_doc: notification is best-effort; swallow all errors.
    }
  } else {
    try {
      [System.Reflection.Assembly]::LoadWithPartialName('System.Windows.Forms') > $null
      [System.Windows.Forms.MessageBox]::Show($Message, $Title, 'OK', 'Information') > $null
    } catch {
      # check-suppress:suppression_doc: notification is best-effort; swallow all errors.
    }
  }
}

# Never degrades to a toast: the caller passes -Dialog because nothing else is
# visible.
function Show-NucleusPopup {
  # check-suppress:SuppressMessageAttribute: PSAvoidUsingEmptyCatchBlock -- the dialog is best-effort; the run already reported the same list to stderr
  [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingEmptyCatchBlock', '')]
  param([string]$Title, [string]$Message)
  try {
    Add-Type -AssemblyName System.Windows.Forms
    [System.Windows.Forms.MessageBox]::Show($Message, $Title, 'OK', 'Warning') > $null
  } catch {
    # check-suppress:suppression_doc: dialog is best-effort; swallow all errors.
  }
}

# WHY: the list is capped, since a message box has no scrollbar. ASCII only,
# because Windows PowerShell 5.1 decodes a BOM-less .ps1 as ANSI and a non-ASCII
# glyph would reach the popup as mojibake.
function ConvertTo-NucleusStripMetadataReport {
  param(
    [int]$Processed,
    [int]$Total,
    [string[]]$NotProcessed
  )
  $max = 10
  $lines = [System.Collections.Generic.List[string]]::new()
  $lines.Add("Stripped metadata from $Processed of $Total file(s).")
  $lines.Add('')
  $lines.Add("Not processed ($($NotProcessed.Count)):")
  for ($i = 0; $i -lt $NotProcessed.Count; $i++) {
    if ($i -ge $max) {
      $lines.Add("... and $($NotProcessed.Count - $i) more.")
      break
    }
    $parts = $NotProcessed[$i] -split '\|', 2
    $lines.Add("- $(Split-Path -Leaf $parts[1]) - $($parts[0])")
  }
  return ($lines -join [Environment]::NewLine)
}

$modulePath = Join-Path $PSScriptRoot '..\src\platforms\Windows\modules\Format-NucleusOutput.psm1'
Import-Module $modulePath -Force -DisableNameChecking

$script:SandboxedContextBlock = 'You are inside the srt sandbox. The repo and the granted scratch paths work normally, but the fence is real: network destinations and Unix sockets are allowlisted, some paths are read-only, git config hooks and secrets are protected, and deletions land in the Trash through the safe wrapper (Finder ''Put Back'' is unavailable because Apple Events are denied). If a command fails with a permission or socket error, assume the fence before assuming a bug, say what you need, and use `pi-unrestricted` only when the task genuinely needs the unsandboxed host.'
$script:UnsandboxedContextBlock = 'You are outside the srt sandbox, so the full host is reachable. That is more power than the sandboxed default, so treat deletions, secrets, and network calls with extra care; the safe-delete rules still apply, and a command that worked here may be blocked in the sandbox when you switch back.'

function Get-NucleusSandboxState {
  [CmdletBinding()]
  [OutputType([hashtable])]
  param()

  $raw = [Environment]::GetEnvironmentVariable('SANDBOX_RUNTIME')
  # GetEnvironmentVariable returns $null when unset and "" when set to empty, so
  # distinguish via the environment-variable map.
  $envVars = [Environment]::GetEnvironmentVariables()
  if (-not $envVars.Contains('SANDBOX_RUNTIME')) {
    return @{ State = 'unsandboxed'; Evidence = 'SANDBOX_RUNTIME unset' }
  }
  if ([string]::IsNullOrEmpty($raw)) {
    return @{ State = 'unsandboxed'; Evidence = 'SANDBOX_RUNTIME empty string' }
  }
  $normalized = $raw.ToLowerInvariant()
  if ($normalized -eq '0' -or $normalized -eq 'false') {
    return @{ State = 'unsandboxed'; Evidence = "SANDBOX_RUNTIME=$raw (false-like)" }
  }
  return @{ State = 'sandboxed'; Evidence = "SANDBOX_RUNTIME=$raw" }
}

function Get-NucleusUserRootPath {
  [CmdletBinding()]
  [OutputType([string])]
  param()

  $homeDir = if (-not [string]::IsNullOrEmpty($env:HOME)) { $env:HOME } else { $HOME }
  if ($IsMacOS) {
    return (Join-Path -Path $homeDir -ChildPath 'Library/Application Support/nucleus')
  }
  if ($IsWindows) {
    if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
      return (Join-Path -Path $homeDir -ChildPath '.local/share/nucleus')
    }
    return (Join-Path -Path $env:LOCALAPPDATA -ChildPath 'nucleus')
  }
  return (Join-Path -Path $homeDir -ChildPath '.local/share/nucleus')
}

function Get-SandboxContextInjectOnChange {
  [CmdletBinding()]
  [OutputType([bool])]
  param()

  $homeDir = if (-not [string]::IsNullOrEmpty($env:HOME)) { $env:HOME } else { $HOME }
  $configFile = Join-Path -Path $homeDir -ChildPath '.local/state/nucleus/config.json'
  if (-not (Test-Path -LiteralPath $configFile -PathType Leaf)) { return $true }
  try {
    $raw = Get-Content -LiteralPath $configFile -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) { return $true }
    $parsed = ConvertFrom-Json -InputObject $raw -AsHashtable
    if ($parsed -isnot [hashtable]) { return $true }
    if (-not $parsed.ContainsKey('sandbox-context')) { return $true }
    $section = $parsed['sandbox-context']
    if ($section -isnot [hashtable]) { return $true }
    if (-not $section.ContainsKey('inject-on-change')) { return $true }
    $value = $section['inject-on-change']
    if ($value -is [bool]) { return $value }
  } catch {
    return $true
  }
  return $true
}

function Get-SandboxContextSessionId {
  [CmdletBinding()]
  [OutputType([string])]
  param(
    [AllowEmptyString()]
    [string]$Payload,
    [AllowEmptyString()]
    [string]$ExplicitId
  )

  if (-not [string]::IsNullOrEmpty($ExplicitId)) { return $ExplicitId }
  if ([string]::IsNullOrWhiteSpace($Payload)) { return 'default' }
  try {
    $parsed = ConvertFrom-Json -InputObject $Payload -AsHashtable
    if ($parsed -isnot [hashtable]) { return 'default' }
    foreach ($key in @('session_id', 'sessionId', 'sessionID', 'conversation_id', 'conversationId')) {
      if ($parsed.ContainsKey($key)) {
        $value = [string]$parsed[$key]
        if (-not [string]::IsNullOrEmpty($value)) { return $value }
      }
    }
  } catch {
    return 'default'
  }
  return 'default'
}

function Get-SandboxContextFullBlock {
  [CmdletBinding()]
  [OutputType([string])]
  param([string]$State)
  if ($State -eq 'sandboxed') { return $script:SandboxedContextBlock }
  return $script:UnsandboxedContextBlock
}

function Get-SandboxContextChangeNotice {
  [CmdletBinding()]
  [OutputType([string])]
  param([string]$From, [string]$To)
  if ($From -eq 'sandboxed' -and $To -eq 'unsandboxed') {
    return "Sandbox state changed: sandboxed -> unsandboxed. $($script:UnsandboxedContextBlock)"
  }
  if ($From -eq 'unsandboxed' -and $To -eq 'sandboxed') {
    return "Sandbox state changed: unsandboxed -> sandboxed. $($script:SandboxedContextBlock)"
  }
  return "Sandbox state changed: $From -> $To."
}

function Write-SandboxContextMessage {
  [CmdletBinding()]
  param(
    [string]$Format,
    [string]$Message
  )
  switch ($Format) {
    'text' {
      Write-Output $Message
    }
    'claude' {
      $doc = [ordered]@{
        hookSpecificOutput = [ordered]@{
          hookEventName     = 'UserPromptSubmit'
          additionalContext = $Message
        }
      }
      Write-Output (ConvertTo-Json -InputObject $doc -Compress -Depth 5)
    }
    'cursor' {
      # Cursor prompt-visible injection protocol is unverified in this
      # repository, so cursor format records without emitting.
    }
    'check' {
      # check records without emitting.
    }
    default {
      Write-Output $Message
    }
  }
}

function Invoke-NucleusSandboxContext {
  [CmdletBinding()]
  param(
    [string[]]$ArgumentList
  )

  $harness = ''
  $format = 'text'
  $sessionIdArg = ''
  $help = $false

  $argv = @($ArgumentList)
  if ($argv.Count -eq 0) {
    Write-NucleusError 'sandbox-context requires a harness name'
    exit 1
  }
  if ($argv[0] -eq '-h' -or $argv[0] -eq '--help') {
    Write-NucleusInfo 'usage: nucleus-utils sandbox-context <harness> [--format <text|claude|cursor|check>] [--session-id <id>]'
    exit 0
  }
  $harness = [string]$argv[0]
  $i = 1
  while ($i -lt $argv.Count) {
    $arg = [string]$argv[$i]
    if ($arg -eq '--format' -and $i + 1 -lt $argv.Count) {
      $format = [string]$argv[$i + 1]
      $i += 2
      continue
    }
    if ($arg.StartsWith('--format=')) {
      $format = $arg.Substring('--format='.Length)
      $i += 1
      continue
    }
    if ($arg -eq '--session-id' -and $i + 1 -lt $argv.Count) {
      $sessionIdArg = [string]$argv[$i + 1]
      $i += 2
      continue
    }
    if ($arg.StartsWith('--session-id=')) {
      $sessionIdArg = $arg.Substring('--session-id='.Length)
      $i += 1
      continue
    }
    if ($arg -eq '--help' -or $arg -eq '-h') {
      $help = $true
      $i += 1
      continue
    }
    Write-NucleusError "unknown sandbox-context option: $arg"
    exit 1
  }
  if ($help) {
    Write-NucleusInfo 'usage: nucleus-utils sandbox-context <harness> [--format <text|claude|cursor|check>] [--session-id <id>]'
    exit 0
  }
  if ($format -notin @('text', 'claude', 'cursor', 'check')) {
    Write-NucleusError "unknown sandbox-context format: $format"
    exit 1
  }

  $payload = ''
  if ([Console]::IsInputRedirected) {
    $payload = [Console]::In.ReadToEnd()
  }

  $sessionId = Get-SandboxContextSessionId -Payload $payload -ExplicitId $sessionIdArg
  $detected = Get-NucleusSandboxState
  $state = [string]$detected.State
  $evidence = [string]$detected.Evidence
  $injectOnChange = Get-SandboxContextInjectOnChange

  $userRoot = Get-NucleusUserRootPath
  $recordDir = Join-Path -Path (Join-Path -Path (Join-Path -Path $userRoot -ChildPath 'state') -ChildPath 'harness-bridge') -ChildPath 'sandbox'
  $recordFile = Join-Path -Path $recordDir -ChildPath "$harness.json"

  $priorState = 'unknown'
  $corrupt = $false
  $record = $null
  if (Test-Path -LiteralPath $recordFile -PathType Leaf) {
    try {
      $rawRecord = Get-Content -LiteralPath $recordFile -Raw -Encoding UTF8
      $record = ConvertFrom-Json -InputObject $rawRecord -AsHashtable
      if ($record -isnot [hashtable] -or -not $record.ContainsKey('version') -or $record['version'] -ne 1 -or -not $record.ContainsKey('sessions') -or $record['sessions'] -isnot [hashtable]) {
        throw 'invalid sandbox-context record'
      }
      $sessions = $record['sessions']
      if ($sessions.ContainsKey($sessionId) -and $sessions[$sessionId] -is [hashtable] -and $sessions[$sessionId].ContainsKey('state')) {
        $candidate = [string]$sessions[$sessionId]['state']
        if ($candidate -eq 'sandboxed' -or $candidate -eq 'unsandboxed') {
          $priorState = $candidate
        }
      }
    } catch {
      $corrupt = $true
      $record = $null
      [Console]::Error.WriteLine("utils: warning: sandbox-context: corrupt or unreadable record '$recordFile'; treating prior state as unknown")
    }
  }

  $message = ''
  $shouldEmit = $false
  $shouldRecord = $false
  if ($priorState -eq 'unknown') {
    $message = Get-SandboxContextFullBlock -State $state
    $shouldEmit = $true
    $shouldRecord = $true
  } elseif ($priorState -eq $state) {
    # Unchanged: emit nothing and do not rewrite the file.
    exit 0
  } else {
    $message = Get-SandboxContextChangeNotice -From $priorState -To $state
    $shouldEmit = $true
    $shouldRecord = $true
  }

  if ($shouldRecord) {
    $now = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    $cutoff = (Get-Date).ToUniversalTime().AddDays(-30).ToString('yyyy-MM-ddTHH:mm:ssZ')

    if ($corrupt -or $null -eq $record) {
      $record = @{ version = 1; sessions = @{} }
    }
    if (-not $record.ContainsKey('sessions') -or $record['sessions'] -isnot [hashtable]) {
      $record['sessions'] = @{}
    }
    $sessions = $record['sessions']
    $sessions[$sessionId] = @{ state = $state; evidence = $evidence; observedAt = $now }

    $kept = @()
    foreach ($entry in $sessions.GetEnumerator()) {
      $observed = ''
      if ($entry.Value -is [hashtable] -and $entry.Value.ContainsKey('observedAt')) {
        $observed = [string]$entry.Value['observedAt']
      }
      if ($observed -ge $cutoff) {
        $kept += [pscustomobject]@{ Key = [string]$entry.Key; Value = $entry.Value; ObservedAt = $observed }
      }
    }
    $kept = @($kept | Sort-Object -Property ObservedAt)
    if ($kept.Count -gt 50) {
      $kept = @($kept | Select-Object -Last 50)
    }
    $pruned = @{}
    foreach ($item in $kept) {
      $pruned[$item.Key] = $item.Value
    }
    $record['version'] = 1
    $record['sessions'] = $pruned

    $null = New-Item -ItemType Directory -Path $recordDir -Force  # check-suppress:suppression_doc: directory creation output is unused
    $tmpFile = "$recordFile.tmp.$PID"
    try {
      $json = ConvertTo-Json -InputObject $record -Compress -Depth 10
      [System.IO.File]::WriteAllText($tmpFile, $json, [System.Text.UTF8Encoding]::new($false))
      [System.IO.File]::Move($tmpFile, $recordFile, $true)
    } catch {
      Remove-Item -LiteralPath $tmpFile -Force -ErrorAction SilentlyContinue  # check-suppress:suppression_doc: temporary file may not exist after failed write
      Write-NucleusWarning "sandbox-context: could not write record '$recordFile'"
    }
  }

  if ($shouldEmit -and $injectOnChange) {
    Write-SandboxContextMessage -Format $format -Message $message
  }
  exit 0
}

if ($MyInvocation.InvocationName -eq '.') { return }

if ($Help) {
  Get-Help $PSCommandPath -Detailed
  exit 0
}

# A bare invocation prints the usage summary and succeeds, matching utils.sh:
# asking which subcommand to run is not a failure.
if (-not $Action) {
  $scriptName = Split-Path -Leaf $PSCommandPath
  Write-NucleusInfo "usage: $scriptName optimize-pdf [[-Preset] <name>] [[-RemoveBackup]] [-File] <path>... | strip-metadata [[-RemoveBackup]] [[-Dialog]] [-File] <path>... | harness-notify <harness> <event> [text] | harness-approval [-Plain] <harness> <tool> <summary> [timeout-seconds] | harness-filter <harness> | harness-drive <harness> | sandbox-context <harness> [--format <text|claude|cursor|check>] [--session-id <id>] | safe-delete-guard [args]..."
  Write-NucleusInfo "  Grouped nucleus user utilities. optimize-pdf/strip-metadata process files; harness-notify/approval/filter/drive and safe-delete-guard dispatch to harness bridge and deletion-guard implementations; sandbox-context records and reports sandbox state changes."
  Write-NucleusInfo ""
  Write-NucleusInfo "Subcommands:"
  Write-NucleusInfo "  optimize-pdf       Optimize PDF files using Ghostscript. Keeps a .bak backup by default."
  Write-NucleusInfo "  strip-metadata     Strip personal metadata from files (mat2 for OOXML, exiftool otherwise); PDF and legacy OLE2 inputs are skipped."
  Write-NucleusInfo "  harness-notify     Normalize a harness lifecycle event into a Hermes notification."
  Write-NucleusInfo "  harness-approval   Request an approval decision for a harness tool call."
  Write-NucleusInfo "  harness-filter     Read a harness hook payload on stdin and print a decision document."
  Write-NucleusInfo "  harness-drive      End a harness turn: notify and inject one queued remote prompt."
  Write-NucleusInfo "  sandbox-context    Detect, record, and report sandbox state changes for a harness session."
  Write-NucleusInfo "  safe-delete-guard  Evaluate deletion commands against the safe-delete policy."
  Write-NucleusInfo ""
  Write-NucleusInfo "Run $scriptName -Help for the full help text."
  exit 0
}

# Sync-ShellProfile defines Invoke-NucleusGhostscript; define inline as fallback.
# check-suppress:suppression_doc: probe whether function is already defined; Get-Command throws when absent.
if (-not (Get-Command Invoke-NucleusGhostscript -ErrorAction SilentlyContinue)) {
  function Invoke-NucleusGhostscript {
    # check-suppress:suppression_doc: probe whether tool is installed; Get-Command throws when absent.
    if (Get-Command gs -ErrorAction SilentlyContinue) { & gs @Args; return }
    # check-suppress:suppression_doc: probe whether tool is installed; Get-Command throws when absent.
    if (Get-Command gswin64c -ErrorAction SilentlyContinue) { & gswin64c @Args; return }
    # check-suppress:suppression_doc: probe whether tool is installed; Get-Command throws when absent.
    if (Get-Command gswin32c -ErrorAction SilentlyContinue) { & gswin32c @Args; return }
    throw "Ghostscript CLI not found. Expected one of: gs, gswin64c, gswin32c"
  }
}

# check-suppress:suppression_doc: probe whether function is already defined; Get-Command throws when absent.
if (-not (Get-Command Invoke-NucleusExifTool -ErrorAction SilentlyContinue)) {
  function Invoke-NucleusExifTool {
    # check-suppress:suppression_doc: probe whether tool is installed; Get-Command throws when absent.
    if (Get-Command exiftool -ErrorAction SilentlyContinue) { & exiftool @Args; return }
    throw "ExifTool CLI not found. Expected: exiftool"
  }
}

switch ($Action) {
  'optimize-pdf' {
    $validPresets = @("default", "ebook", "prepress", "printer", "screen")
    if ($validPresets -notcontains $Preset) {
      Write-NucleusError "unknown preset '$Preset'. Valid: $($validPresets -join ', ')"
      exit 1
    }

    if ($File.Count -eq 0) {
      Write-NucleusInfo "usage: $(Split-Path -Leaf $PSCommandPath) optimize-pdf [[-Preset] <name>] [[-RemoveBackup]] [-File] <path>..."
      Write-NucleusInfo "presets: $($validPresets -join ', ') (default: default)"
      Write-NucleusInfo "options: -RemoveBackup  Remove the .bak backup on success (kept by default)."
      exit 1
    }

    foreach ($f in $File) {
      if (-not (Test-Path -LiteralPath $f -PathType Leaf)) {
        Write-NucleusWarning "skipping non-file: $f"
        continue
      }

      $bak = "$f.bak"
      if (Test-Path -LiteralPath $bak) {
        Write-NucleusError "backup already exists, refusing to overwrite: $bak"
        exit 1
      }

      Move-Item -LiteralPath $f -Destination $bak -Force
      try {
        Invoke-NucleusGhostscript @(
          "-sDEVICE=pdfwrite",
          "-dCompatibilityLevel=2.0",
          "-dPDFSETTINGS=/$Preset",
          "-dNOPAUSE", "-dQUIET", "-dBATCH",
          "-sOutputFile=$(Resolve-Path $f -Relative)",
          "$bak"
        )
        if ($RemoveBackup) { Remove-Item -LiteralPath $bak -Force }
        Write-NucleusInfo "optimized: $f (preset: $Preset)"
      } catch {
        Move-Item -LiteralPath $bak -Destination $f -Force
        Write-NucleusError "optimization failed, restored: $f"
        exit 1
      }
    }
  }

  'strip-metadata' {
    if ($File.Count -eq 0) {
      Write-NucleusInfo "usage: $(Split-Path -Leaf $PSCommandPath) strip-metadata [[-RemoveBackup]] [-Dialog] [-File] <path>..."
      Write-NucleusInfo "options: -RemoveBackup  Remove the .bak backup on success (kept by default)."
      Write-NucleusInfo "options: -Dialog  Show one popup listing every input that was not processed."
      exit 1
    }

    # Collected across the whole run, because one hidden host cannot show
    # anything per file.
    $notProcessed = [System.Collections.Generic.List[string]]::new()
    $processed = 0
    $failed = 0

    foreach ($f in $File) {
      if (-not (Test-Path -LiteralPath $f -PathType Leaf)) {
        Write-NucleusWarning "skipping non-file: $f"
        $notProcessed.Add("not a file|$f")
        continue
      }

      $bak = "$f.bak"
      if (Test-Path -LiteralPath $bak) {
        # check-suppress:suppression_doc: keep going after a refused input; the failure is recorded and reported at the end.
        Write-NucleusError "backup already exists, refusing to overwrite: $bak" -ErrorAction 'Continue'
        $notProcessed.Add("a .bak backup already exists|$f")
        $failed++
        continue
      }

      $ext = [System.IO.Path]::GetExtension($f).ToLower()
      if ($ext -eq '.pdf') {
        Write-NucleusWarning "skipping PDF (strip-metadata does not support PDF files): $f"
        $notProcessed.Add("PDF files are not supported|$f")
        if (-not $Dialog) {
          Show-NucleusNotification -Title 'strip metadata' -Message "Skipped PDF (not supported): $f"
        }
        continue
      }
      if ($ext -in @('.docx', '.xlsx', '.pptx')) {
        # OOXML goes through mat2.
        # check-suppress:suppression_doc: probe whether tool is installed; Get-Command throws when absent.
        if (-not (Get-Command mat2 -ErrorAction SilentlyContinue)) {
          Write-NucleusWarning "mat2 not found, cannot strip OOXML metadata: $f"
          $notProcessed.Add("mat2 is not installed|$f")
          continue
        }
        Copy-Item -LiteralPath $f -Destination $bak -Force
        try {
          & mat2 --inplace $f
          # WHY: thrown rather than exiting so the remaining inputs are still attempted.
          if ($LASTEXITCODE -ne 0) { throw "mat2 exited with $LASTEXITCODE" }
          if ($RemoveBackup) { Remove-Item -LiteralPath $bak -Force }
          $processed++
          Write-NucleusInfo "stripped metadata: $f"
          Show-NucleusNotification -Title 'strip metadata' -Message "Stripped metadata: $f"
        } catch {
          Move-Item -LiteralPath $bak -Destination $f -Force
          # check-suppress:suppression_doc: keep going after a failed input; the failure is recorded and reported at the end.
          Write-NucleusError "metadata stripping failed, restored: $f" -ErrorAction 'Continue'
          $notProcessed.Add("metadata stripping failed, original restored|$f")
          $failed++
        }
      } elseif ($ext -in @('.doc', '.xls', '.ppt')) {
        # Legacy OLE2: neither mat2 nor exiftool can write these formats.
        Write-NucleusWarning "skipping legacy OLE2 (no CLI tool can write this format): $f"
        $notProcessed.Add("legacy OLE2 is not supported|$f")
        if (-not $Dialog) {
          Show-NucleusNotification -Title 'strip metadata' -Message "Skipped legacy OLE2 (unsupported format): $f"
        }
      } else {
        # WHY: backup first, then in-place strip, so an interrupt leaves either
        # the original or the stripped file, never a half-written one.
        Copy-Item -LiteralPath $f -Destination $bak -Force
        try {
          Invoke-NucleusExifTool @(
            "-all=",
            "-overwrite_original",
            $f
          )
          if ($RemoveBackup) { Remove-Item -LiteralPath $bak -Force }
          $processed++
          Write-NucleusInfo "stripped metadata: $f"
          Show-NucleusNotification -Title 'strip metadata' -Message "Stripped metadata: $f"
        } catch {
          Move-Item -LiteralPath $bak -Destination $f -Force
          # check-suppress:suppression_doc: keep going after a failed input; the failure is recorded and reported at the end.
          Write-NucleusError "metadata stripping failed, restored: $f" -ErrorAction 'Continue'
          $notProcessed.Add("metadata stripping failed, original restored|$f")
          $failed++
        }
      }
    }

    # Reported once, after every input has been attempted.
    if ($Dialog -and $notProcessed.Count -gt 0) {
      $reportArgs = @{
        Processed = $processed
        Total = $File.Count
        NotProcessed = $notProcessed.ToArray()
      }
      Show-NucleusPopup -Title 'strip metadata' -Message (ConvertTo-NucleusStripMetadataReport @reportArgs)
    }

    if ($failed -gt 0) { exit 1 }
  }

  'harness-notify' {
    $scriptPath = Join-Path $PSScriptRoot '..\src\scripts\notify\harness-notify.ps1'
    & $scriptPath @File
    exit $LASTEXITCODE
  }

  'harness-approval' {
    $scriptPath = Join-Path $PSScriptRoot '..\src\scripts\notify\harness-approval.ps1'
    $forwardArgs = @()
    if ($Plain) { $forwardArgs += '-Plain' }
    if ($File) { $forwardArgs += $File }
    & $scriptPath @forwardArgs
    exit $LASTEXITCODE
  }

  'harness-filter' {
    $scriptPath = Join-Path $PSScriptRoot '..\src\scripts\notify\harness-filter.ps1'
    & $scriptPath @File
    exit $LASTEXITCODE
  }

  'harness-drive' {
    $scriptPath = Join-Path $PSScriptRoot '..\src\scripts\notify\harness-drive.ps1'
    & $scriptPath @File
    exit $LASTEXITCODE
  }

  'sandbox-context' {
    Invoke-NucleusSandboxContext -ArgumentList $File
  }

  'safe-delete-guard' {
    $scriptPath = Join-Path $PSScriptRoot '..\src\scripts\notify\filters\safe-delete.ts'
    & bun $scriptPath @File
    exit $LASTEXITCODE
  }
}
