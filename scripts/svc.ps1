<#
.SYNOPSIS
  Unified service management and log inspection for Windows (windows-native, windows-schtask).

.DESCRIPTION
  Services come from src/modules/services.json, addressed by registry key. Entries flagged
  prefixMatch stand in for one runtime service per instance: list and status print each
  instance id, and every action takes either the key (all live instances) or an exact
  instance id. An instance the user registry declares but Windows does not run reports
  not-loaded: acting on that exact id fails with a remedy, acting on the key warns and
  keeps the exit status of the instances that did run. Nothing is loaded automatically.

.PARAMETER Action
  The operation to perform: list, status, start, stop, restart, enable, disable,
  endpoint, logs, log-paths, log-config.

.PARAMETER ServiceName
  Service names to target. For endpoint, first is the service name and the optional second
  is the endpoint name.

.NOTES
  Environment variables: NUCLEUS_REPO_ROOT.
  Exit codes: 0 on success; non-zero on failure.
#>
[CmdletBinding()]
param(
  [Parameter(Position = 0)]
  [ValidateSet('list', 'status', 'start', 'stop', 'restart', 'enable', 'disable', 'verify', 'endpoint', 'logs', 'log-paths', 'log-config')]
  [string]$Action,

  [Parameter(Position = 1, ValueFromRemainingArguments = $true)]
  [string[]]$ServiceName = @(),

  [switch]$Json,

  [Alias("h")]
  [switch]$Help,

  # Internal: set by the self-elevation re-exec so the elevated child does not
  # re-trigger elevation.
  [switch]$Elevated
)

$ErrorActionPreference = 'Stop'

$modulePath = Join-Path $PSScriptRoot '..\src\platforms\Windows\modules\Format-NucleusOutput.psm1'
Import-Module $modulePath -Force -DisableNameChecking

if ($Help) {
  Get-Help $PSCommandPath -Detailed
  exit 0
}

# A missing action is an error, matching svc.sh (message on stderr, exit 1):
# callers act on the result of a service operation, so a run that performed
# nothing must not read as success.
if (-not $Action) {
  Write-NucleusError "missing action (list, status, start, stop, restart, enable, disable, verify, endpoint, logs, log-paths, log-config)"
  exit 1
}

$RepoRoot = if ($env:NUCLEUS_REPO_ROOT) { $env:NUCLEUS_REPO_ROOT } else { (Get-Item $PSScriptRoot).Parent.FullName }
$ServicesJson = Join-Path $RepoRoot "src\modules\services.json"
$NucleusHost = 'Windows'

# Set when elevation was requested but could not be obtained (UAC cancelled / no admin).
# System-scope entries are then skipped with a warning instead of failing the run.
$SkipSystemScope = $false

$isAdmin = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $Elevated -and -not $isAdmin) {
  $params = @{
    Action      = $Action
    ServiceName = $ServiceName
    Json        = $Json.IsPresent
    Elevated    = $true
  }
  $paramsJsonPath = [System.IO.Path]::GetTempFileName() + ".json"
  $params | ConvertTo-Json -Compress | Set-Content $paramsJsonPath -Encoding utf8 -NoNewline

  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = (Get-Process -Id $PID).Path
  $psi.Arguments = "-NoProfile -File `"$PSCommandPath`" -ParamsJson `"$paramsJsonPath`""
  $psi.Verb = "RunAs"
  $psi.UseShellExecute = $true
  try {
    $proc = [System.Diagnostics.Process]::Start($psi)
  } catch {
    $proc = $null
  }
  if ($null -eq $proc) {
    Remove-Item $paramsJsonPath -Force -ErrorAction SilentlyContinue  # check-suppress:suppression_doc: temp file cleanup; failure harmless (%TEMP% recycled)
    Write-NucleusWarning "svc: elevation unavailable (UAC cancelled or no admin) — system-scope operations will be skipped"
    $SkipSystemScope = $true
  } else {
    $proc.WaitForExit()
    $exitCode = $proc.ExitCode
    Remove-Item $paramsJsonPath -Force -ErrorAction SilentlyContinue  # check-suppress:suppression_doc: temp file cleanup; child may have cleaned up
    exit $exitCode
  }
}

# Read and parse registry
if (-not (Test-Path $ServicesJson)) {
  throw "svc: services registry not found at $ServicesJson"
}
$RegistryRaw = Get-Content $ServicesJson -Raw | ConvertFrom-Json -AsHashtable

# Filter to Windows-relevant services
$Registry = @{}
foreach ($svc in $RegistryRaw.Keys) {
  $entry = $RegistryRaw[$svc]
  if ($entry -is [hashtable] -and $entry.hosts.ContainsKey($NucleusHost) -and $entry.hosts[$NucleusHost].type -ne 'omitted') {
    $Registry[$svc] = @{
      displayName = $entry.displayName
      description = $entry.description
      network     = if ($entry.PSObject.Properties.Name -contains 'network') { $entry.network } else { $null }
      hostEntry   = $entry.hosts[$NucleusHost]
    }
  }
}

# Load log management helpers
. (Join-Path -Path $RepoRoot -ChildPath "src\platforms\Windows\modules\Invoke-LogManagement.ps1")
. (Join-Path -Path $RepoRoot -ChildPath "src\platforms\Windows\modules\Get-NucleusServiceInstance.ps1")

function New-ResolvedRow {
  <#
  .SYNOPSIS
    Builds one resolution row: the registry key, display name, host entry, instance id and
    class (live, pseudo, configured or error) the status and action helpers consume.
  #>
  # check-suppress:SuppressMessageAttribute: PSUseShouldProcessForStateChangingFunctions -- pure builder of an in-memory row; no system state changes
  [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
  param(
    [string]$RegistryKey,
    [string]$DisplayName,
    [hashtable]$HostEntry,
    [string]$InstanceId,
    [ValidateSet('live', 'pseudo', 'configured', 'error')]
    [string]$Class
  )

  return @{
    registryKey = $RegistryKey
    displayName = $DisplayName
    hostEntry   = $HostEntry
    instanceId  = $InstanceId
    class       = $Class
  }
}

function Resolve-RegistryEntry {
  <#
  .SYNOPSIS
    Emits the resolution rows for one registry entry.

  # A prefix-match entry with neither live nor declared instances yields one pseudo row
  # carrying the registry host entry unchanged, so scope filtering still works and nothing
  # is probed.
  #>
  param(
    [string]$Key,
    [hashtable]$Entry
  )

  $hostEntry = $Entry.hostEntry
  $rowParameters = @{
    RegistryKey = $Key
    DisplayName = $Entry.displayName
    HostEntry   = $hostEntry
    InstanceId  = $Key
    Class       = 'live'
  }

  if (-not ($hostEntry.ContainsKey('prefixMatch') -and $hostEntry.prefixMatch)) {
    return @(New-ResolvedRow @rowParameters)
  }

  $instances = @(Get-NucleusPrefixInstanceList -HostEntry $hostEntry)
  $configured = @(Get-NucleusConfiguredInstanceList -HostEntry $hostEntry -Username $env:USERNAME | Where-Object { $instances -notcontains $_ })
  if ($instances.Count -eq 0 -and $configured.Count -eq 0) {
    $rowParameters.Class = 'pseudo'
    return @(New-ResolvedRow @rowParameters)
  }

  $liveRows = @($instances | ForEach-Object {
      $rowParameters.InstanceId = $_
      $rowParameters.DisplayName = "$($Entry.displayName) ($(Get-NucleusInstanceSuffix -HostEntry $hostEntry -InstanceId $_))"
      $rowParameters.HostEntry = New-NucleusInstanceHostEntry -HostEntry $hostEntry -InstanceId $_
      New-ResolvedRow @rowParameters
    })

  $configuredRows = @($configured | ForEach-Object {
      $rowParameters.InstanceId = $_
      $rowParameters.DisplayName = "$($Entry.displayName) ($(Get-NucleusInstanceSuffix -HostEntry $hostEntry -InstanceId $_))"
      $rowParameters.HostEntry = New-NucleusInstanceHostEntry -HostEntry $hostEntry -InstanceId $_
      $rowParameters.HostEntry.configured = $true
      $rowParameters.Class = 'configured'
      New-ResolvedRow @rowParameters
    })

  return @($liveRows + $configuredRows)
}

function Resolve-InstanceId {
  <#
  .SYNOPSIS
    Resolves a concrete instance id that is not a registry key.

  # list and status print concrete instance ids, so they must be accepted as arguments.
  # An id under a prefix-match prefix that is neither live nor declared yields an error row
  # naming the prefix; a name matching no prefix yields $null so the caller calls it unknown.
  #>
  param(
    [string]$Name
  )

  foreach ($key in $Registry.Keys) {
    $hostEntry = $Registry[$key].hostEntry
    if (-not ($hostEntry.ContainsKey('prefixMatch') -and $hostEntry.prefixMatch)) { continue }

    $prefix = Get-NucleusInstanceIdPrefix -HostEntry $hostEntry
    if (-not $Name.StartsWith($prefix, [System.StringComparison]::Ordinal)) { continue }

    $instances = @(Get-NucleusPrefixInstanceList -HostEntry $hostEntry)
    $isLive = $instances -contains $Name
    if (-not $isLive) {
      $configured = @(Get-NucleusConfiguredInstanceList -HostEntry $hostEntry -Username $env:USERNAME)
      if ($configured -notcontains $Name) {
        $errorEntry = @{ error = "no such instance (prefix '$prefix'); run 'nucleus-svc list'" }
        return New-ResolvedRow -RegistryKey "ERROR:$Name" -DisplayName $Name -HostEntry $errorEntry -InstanceId $Name -Class 'error'
      }
    }

    $displayName = "$($Registry[$key].displayName) ($(Get-NucleusInstanceSuffix -HostEntry $hostEntry -InstanceId $Name))"
    $instanceEntry = New-NucleusInstanceHostEntry -HostEntry $hostEntry -InstanceId $Name
    if ($isLive) {
      return New-ResolvedRow -RegistryKey $key -DisplayName $displayName -HostEntry $instanceEntry -InstanceId $Name -Class 'live'
    }
    $instanceEntry.configured = $true
    return New-ResolvedRow -RegistryKey $key -DisplayName $displayName -HostEntry $instanceEntry -InstanceId $Name -Class 'configured'
  }

  return $null
}

function Resolve-ServiceName {
  <#
  .SYNOPSIS
    Resolves the requested service names into rows. With no names, every registry entry is
    resolved, prefix-match entries included.
  #>
  param(
    [string[]]$Names
  )

  $rows = @()

  if ($Names.Count -eq 0) {
    foreach ($key in $Registry.Keys) {
      $rows += Resolve-RegistryEntry -Key $key -Entry $Registry[$key]
    }
    return $rows
  }

  foreach ($name in $Names) {
    if ($Registry.ContainsKey($name)) {
      $rows += Resolve-RegistryEntry -Key $name -Entry $Registry[$name]
      continue
    }
    $instanceRow = Resolve-InstanceId -Name $name
    if ($null -ne $instanceRow) {
      $rows += $instanceRow
      continue
    }
    $errorEntry = @{ error = 'service not found in registry' }
    $rows += New-ResolvedRow -RegistryKey "ERROR:$name" -DisplayName $name -HostEntry $errorEntry -InstanceId $name -Class 'error'
  }
  return $rows
}

function Get-InstanceArgument {
  # Log lookups take an instance id only for a row addressing a concrete instance, so the
  # key and the id are compared rather than assumed to differ.
  param(
    [hashtable]$Row
  )

  if ($Row.instanceId -eq $Row.registryKey) { return '' }
  return $Row.instanceId
}

function New-StatusRow {
  <#
  .SYNOPSIS
    Builds one status-table row from a resolution row.

  # Configured rows are declared but not running, so they report not-loaded without a probe.
  # Pseudo and error rows have no runtime identity and report n/a, since a probe would
  # report a false inactive status.
  #>
  # check-suppress:SuppressMessageAttribute: PSUseShouldProcessForStateChangingFunctions -- pure builder of an in-memory row; the probe itself is read-only
  [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
  param(
    [hashtable]$ResolvedRow
  )

  if ($ResolvedRow.class -ne 'live') {
    $row = @{
      class       = $ResolvedRow.class
      id          = $ResolvedRow.instanceId
      displayName = $ResolvedRow.displayName
      status      = if ($ResolvedRow.class -eq 'configured') { 'not-loaded' } else { 'n/a' }
      running     = '-'
      pid         = '-'
    }
    if ($ResolvedRow.class -eq 'configured') { $row.configured = $true }
    return $row
  }

  $status = Get-ServiceStatus -HostEntry $ResolvedRow.hostEntry
  $status.class = 'live'
  $status.id = $ResolvedRow.instanceId
  $status.displayName = $ResolvedRow.displayName
  return $status
}

function Test-ServiceIsSystemScope {
  param(
    [hashtable]$ResolvedEntry
  )
  $plat = $ResolvedEntry.hostEntry
  if ($null -eq $plat -or -not $plat.ContainsKey('scope')) { return $false }
  return $plat.scope -eq 'system'
}

function Get-ServiceStatus {
  param(
    [hashtable]$HostEntry
  )

  $type = $HostEntry.type

  switch ($type) {
    'windows-native' {
      $svcName = $HostEntry.service
      try {
        $svc = Get-Service -Name $svcName -ErrorAction Stop
        $running = $svc.Status -eq 'Running'
        $enabled = $svc.StartType -in @('Automatic', 'AutomaticDelayedStart')
        $processId = $null
        if ($running) {
          $processId = (Get-CimInstance -ClassName Win32_Service -Filter "Name='$svcName'" -ErrorAction SilentlyContinue  # check-suppress:suppression_doc: probe -- service may not exist (race condition); $processId becomes $null and handled below
          ).ProcessId
          if ($processId -eq 0) { $processId = $null }
        }
        return @{
          status  = if ($running) { 'active' } else { 'inactive' }
          running = $running
          enabled = $enabled
          pid     = $processId
        }
      } catch {
        return @{ status = 'not-found'; running = $false; enabled = $false; pid = $null }
      }
    }
    'windows-schtask' {
      $taskPath = $HostEntry.taskPath
      try {
        $task = Get-ScheduledTask -TaskPath (Split-Path $taskPath -Parent) -TaskName (Split-Path $taskPath -Leaf) -ErrorAction Stop
        $enabled = $task.State -ne 'Disabled'
        $running = $task.State -eq 'Running'
        return @{
          status  = if ($running) { 'active' } elseif ($enabled) { 'inactive' } else { 'disabled' }
          running = $running
          enabled = $enabled
        }
      } catch {
        return @{ status = 'not-found'; running = $false; enabled = $false }
      }
    }
    default {
      return @{ status = 'unknown'; running = $false; enabled = $false; error = "unsupported type: $type" }
    }
  }
}

function Invoke-ServiceAction {
  param(
    [string]$Action,
    [hashtable]$HostEntry
  )

  $type = $HostEntry.type

  switch ($type) {
    'windows-native' {
      $svcName = $HostEntry.service
      switch ($Action) {
        'status'  { return Get-ServiceStatus -HostEntry $HostEntry }
        'start'   { Start-Service -Name $svcName -ErrorAction Stop; return $true }
        'stop'    { Stop-Service -Name $svcName -ErrorAction Stop -Force; return $true }
        'restart' { Restart-Service -Name $svcName -ErrorAction Stop -Force; return $true }
        'enable'  { Set-Service -Name $svcName -StartupType Automatic -ErrorAction Stop; return $true }
        'disable' { Set-Service -Name $svcName -StartupType Disabled -ErrorAction Stop; return $true }
      }
    }
    'windows-schtask' {
      $taskPath = $HostEntry.taskPath
      $taskName = Split-Path $taskPath -Leaf
      $taskParent = Split-Path $taskPath -Parent
      switch ($Action) {
        'status'  { return Get-ServiceStatus -HostEntry $HostEntry }
        'start'   { Start-ScheduledTask -TaskPath $taskParent -TaskName $taskName -ErrorAction Stop; return $true }
        'stop'    { Stop-ScheduledTask -TaskPath $taskParent -TaskName $taskName -ErrorAction Stop; return $true }
        'restart' { Stop-ScheduledTask -TaskPath $taskParent -TaskName $taskName -ErrorAction SilentlyContinue  # check-suppress:suppression_doc: best-effort stop before start -- task may not be running
          ; Start-ScheduledTask -TaskPath $taskParent -TaskName $taskName -ErrorAction Stop; return $true }
        'enable'  { Enable-ScheduledTask -TaskPath $taskParent -TaskName $taskName -ErrorAction Stop; return $true }
        'disable' { Disable-ScheduledTask -TaskPath $taskParent -TaskName $taskName -ErrorAction Stop; return $true }
      }
    }
    default {
      throw "svc: unsupported service type: $type"
    }
  }
}

function Format-StatusTable {
  param(
    [object[]]$Rows
  )

  if ($Json) {
    $jsonObj = @{ version = 1; services = [ordered]@{} }
    foreach ($row in $Rows) {
      if ($row.class -eq 'error') { continue }
      # class is a resolution detail; the JSON contract keeps the status fields only.
      $entry = @{}
      foreach ($key in $row.Keys) {
        if ($key -ne 'class') { $entry[$key] = $row[$key] }
      }
      $jsonObj.services[$row.id] = $entry
    }
    return ($jsonObj | ConvertTo-Json -Depth 3 -Compress)
  }

  $lines = @()
  $lines += "{0,-20} {1,-24} {2,-10} {3,-8} {4}" -f 'ID', 'Name', 'Status', 'Running', 'PID'
  $lines += '-' * 80

  foreach ($row in $Rows) {
    $pidText = if ($row.pid) { $row.pid } else { '-' }
    $lines += "{0,-20} {1,-24} {2,-10} {3,-8} {4}" -f $row.id, $row.displayName, $row.status, $row.running, $pidText
  }
  return $lines -join "`n"
}

function Get-HostService {
  $Registry.Keys | Sort-Object
}

function Get-LogEntry {
  param([string]$ServiceKey)
  $entry = $RegistryRaw[$ServiceKey]
  $hostLog = if ($entry.hosts[$NucleusHost].ContainsKey('logging')) { $entry.hosts[$NucleusHost].logging } else { $null }
  $topLog = if ($entry.ContainsKey('logging')) { $entry.logging } else { $null }
  return @{ host = $hostLog; top = $topLog }
}

function Get-CaptureMode {
  param([string]$ServiceKey)
  $logEntry = Get-LogEntry -ServiceKey $ServiceKey
  $hostLog = $logEntry.host
  $topLog = $logEntry.top
  if ($hostLog -and $hostLog.ContainsKey('capture')) { return $hostLog.capture }
  if ($topLog -and $topLog.ContainsKey('capture')) { return $topLog.capture }
  return 'all'
}

function Get-EventLogConfig {
  param([string]$ServiceKey)
  $entry = $RegistryRaw[$ServiceKey]
  $eventLog = $null
  if ($entry.hosts[$NucleusHost].ContainsKey('logging') -and $entry.hosts[$NucleusHost].logging.ContainsKey('eventLog')) {
    $eventLog = $entry.hosts[$NucleusHost].logging.eventLog
  } elseif ($entry.ContainsKey('logging') -and $entry.logging.ContainsKey('eventLog')) {
    $eventLog = $entry.logging.eventLog
  }
  return $eventLog
}

function Get-ServiceLogDirList {
  <#
  .SYNOPSIS
    Lists the log directories of a service, or of one of its instances.

  # Top-level logging.dirs covers the whole service. A prefix-match host entry adds
  # logging.instanceDirs, whose <instance> placeholder expands to the instance suffix;
  # without InstanceId every live instance is expanded so an aggregate query reports all.
  #>
  param([string]$ServiceKey, [string]$InstanceId)

  $entry = $RegistryRaw[$ServiceKey]
  $dirs = @()
  if ($entry.ContainsKey('logging') -and $entry.logging.ContainsKey('dirs')) {
    if ($entry.logging.dirs.user) {
      foreach ($subdir in $entry.logging.dirs.user) {
        $dirs += Join-Path (Get-NucleusLogDir) $subdir
      }
    }
    if ($entry.logging.dirs.system) {
      foreach ($subdir in $entry.logging.dirs.system) {
        $dirs += Join-Path (Get-NucleusSystemLogDir) $subdir
      }
    }
  }

  $hostEntry = $entry.hosts[$NucleusHost]
  if (-not ($hostEntry.ContainsKey('logging') -and $hostEntry.logging.ContainsKey('instanceDirs'))) {
    return [string[]]$dirs
  }

  $instanceDirs = $hostEntry.logging.instanceDirs
  $ids = @()
  if (-not [string]::IsNullOrWhiteSpace($InstanceId)) {
    $ids = @($InstanceId)
  } elseif ($hostEntry.ContainsKey('prefixMatch') -and $hostEntry.prefixMatch) {
    $ids = @(Get-NucleusPrefixInstanceList -HostEntry $hostEntry)
  }

  foreach ($id in $ids) {
    $suffix = Get-NucleusInstanceSuffix -HostEntry $hostEntry -InstanceId $id
    foreach ($pattern in @($instanceDirs.user)) {
      if (-not [string]::IsNullOrWhiteSpace($pattern)) {
        $dirs += Join-Path (Get-NucleusLogDir) ($pattern -replace '<instance>', $suffix)
      }
    }
    foreach ($pattern in @($instanceDirs.system)) {
      if (-not [string]::IsNullOrWhiteSpace($pattern)) {
        $dirs += Join-Path (Get-NucleusSystemLogDir) ($pattern -replace '<instance>', $suffix)
      }
    }
  }
  return [string[]]$dirs
}

function Get-ServiceLogFile {
  param([string]$ServiceKey, [string]$InstanceId)
  $files = @()
  foreach ($dir in (Get-ServiceLogDirList -ServiceKey $ServiceKey -InstanceId $InstanceId)) {
    if (Test-Path -LiteralPath $dir -PathType Container) {
      # check-suppress:suppression_doc: probe -- log dir may be empty; empty result handled.
      $files += Get-ChildItem -LiteralPath $dir -Recurse -Filter '*.log' -File -ErrorAction SilentlyContinue |
        Select-Object -ExpandProperty FullName
    }
  }
  return $files | Sort-Object
}

function Test-ServiceHasLog {
  param([string]$ServiceKey, [string]$InstanceId)
  $capture = Get-CaptureMode -ServiceKey $ServiceKey
  if ($capture -ne 'none') {
    $files = Get-ServiceLogFile -ServiceKey $ServiceKey -InstanceId $InstanceId
    if ($files.Count -gt 0) { return $true }
  }
  $eventLog = Get-EventLogConfig -ServiceKey $ServiceKey
  if ($eventLog -and $eventLog.ContainsKey('provider')) {
    # check-suppress:suppression_doc: probe -- event may not exist; expected on fresh systems.
    $evt = Get-WinEvent -ProviderName $eventLog.provider -MaxEvents 1 -ErrorAction SilentlyContinue
    if ($evt) { return $true }
  }
  return $false
}

function Show-FileLog {
  param([string]$ServiceKey, [int]$Lines = 10, [switch]$Raw, [string]$InstanceId)
  $files = Get-ServiceLogFile -ServiceKey $ServiceKey -InstanceId $InstanceId
  if ($files.Count -eq 0) { return $false }
  foreach ($file in $files) {
    $content = Get-Content -LiteralPath $file -Tail $Lines
    if (-not $Raw) { $content = $content | ConvertTo-SanitizedText }
    Write-Output "# $file"
    Write-Output $content
  }
  return $true
}

function Show-EventLog {
  param([string]$ServiceKey, [int]$Lines = 10, [switch]$Raw)
  $eventLog = Get-EventLogConfig -ServiceKey $ServiceKey
  if (-not $eventLog) { return $false }
  $provider = if ($eventLog.ContainsKey('provider')) { $eventLog.provider } else { $null }
  $logName = if ($eventLog.ContainsKey('logName')) { $eventLog.logName } else { 'Application' }
  if (-not $provider) { return $false }
  try {
    $events = Get-WinEvent -LogName $logName -ProviderName $provider -MaxEvents $Lines -ErrorAction Stop
    foreach ($evt in $events) {
      $msg = $evt.Message
      if (-not $Raw) { $msg = $msg | ConvertTo-SanitizedText }
      Write-Output "[$($evt.TimeCreated)] $($evt.LevelDisplayName): $msg"
    }
    return $true
  } catch {
    return $false
  }
}

function Show-ServiceLog {
  param([string]$ServiceKey, [int]$Lines = 10, [switch]$Raw, [string]$InstanceId, [switch]$Configured)
  if (Show-EventLog -ServiceKey $ServiceKey -Lines $Lines -Raw:$Raw) { return }
  $capture = Get-CaptureMode -ServiceKey $ServiceKey
  if ($capture -ne 'none') {
    if (-not (Show-FileLog -ServiceKey $ServiceKey -Lines $Lines -Raw:$Raw -InstanceId $InstanceId)) {
      # WHY: a declared-but-unloaded instance explains why the usual log location is empty.
      $hint = if ($Configured) { ' (configured but not loaded)' } else { '' }
      Write-NucleusWarning "$ServiceKey — no log files found$hint"
    }
  } else {
    Write-NucleusWarning "$ServiceKey — capture disabled"
  }
}

function Show-ServiceList {
  <#
  .SYNOPSIS
    Lists every resolved service row with its log availability.

  # Instance rows are listed under their concrete instance id so a prefix-match entry is
  # visible per instance, matching the POSIX listing.
  #>
  $lines = @()
  foreach ($row in (Resolve-ServiceName -Names @())) {
    $capture = Get-CaptureMode -ServiceKey $row.registryKey
    $instanceId = Get-InstanceArgument -Row $row
    $marker = ''
    if ($row.class -eq 'pseudo') {
      $marker = '  (no instances)'
    } elseif (-not (Test-ServiceHasLog -ServiceKey $row.registryKey -InstanceId $instanceId)) {
      $marker = '  (no logs yet)'
    }
    $lines += "  {0,-30} capture={1,-7}{2}" -f $row.instanceId, $capture, $marker
  }
  return $lines
}

function Show-LogConfig {
  param([string]$ServiceKey, [switch]$JsonOut)
  $lp = Get-LogEntry -ServiceKey $ServiceKey
  $hostLog = $lp.host
  $topLog = $lp.top
  $config = @{
    capture  = if ($hostLog -and $hostLog.ContainsKey('capture')) { $hostLog.capture } elseif ($topLog -and $topLog.ContainsKey('capture')) { $topLog.capture } else { 'all' }
    maxSize  = if ($hostLog -and $hostLog.ContainsKey('maxSize')) { $hostLog.maxSize } elseif ($topLog -and $topLog.ContainsKey('maxSize')) { $topLog.maxSize } else { 10000000 } # bytes
    maxFiles = if ($hostLog -and $hostLog.ContainsKey('maxFiles')) { $hostLog.maxFiles } elseif ($topLog -and $topLog.ContainsKey('maxFiles')) { $topLog.maxFiles } else { 4 }
    compress = if ($hostLog -and $hostLog.ContainsKey('compress')) { $hostLog.compress } elseif ($topLog -and $topLog.ContainsKey('compress')) { $topLog.compress } else { $true }
    sanitize = if ($hostLog -and $hostLog.ContainsKey('sanitize')) { $hostLog.sanitize } elseif ($topLog -and $topLog.ContainsKey('sanitize')) { $topLog.sanitize } else { $true }
    level    = if ($hostLog -and $hostLog.ContainsKey('level')) { $hostLog.level } elseif ($topLog -and $topLog.ContainsKey('level')) { $topLog.level } else { $null }
  }
  $eventLogEntry = if ($hostLog -and $hostLog.ContainsKey('eventLog')) { $hostLog.eventLog } elseif ($topLog -and $topLog.ContainsKey('eventLog')) { $topLog.eventLog } else { $null }
  if ($eventLogEntry) { $config.eventLog = $eventLogEntry }
  if ($JsonOut) {
    Write-Output (@{ version = 1; $ServiceKey = $config } | ConvertTo-Json -Depth 3 -Compress)
  } else {
    Write-Output "${ServiceKey}:"
    foreach ($key in ($config.Keys | Sort-Object)) {
      $val = $config[$key]
      if ($null -ne $val) { Write-Output "  $key`: $val" }
    }
  }
}

switch ($Action) {
  'list' {
    $resolved = Resolve-ServiceName -Names $ServiceName
    $rows = @()
    $hasError = $false
    foreach ($entry in $resolved) {
      if ($entry.class -eq 'error') {
        $rows += New-StatusRow -ResolvedRow $entry
        $hasError = $true
        continue
      }
      if ($SkipSystemScope -and (Test-ServiceIsSystemScope -ResolvedEntry $entry)) {
        Write-NucleusWarning "$($entry.instanceId) — system-scope operation skipped (elevation unavailable)"
        continue
      }
      $rows += New-StatusRow -ResolvedRow $entry
    }
    Write-Output (Format-StatusTable -Rows $rows)
    if ($hasError -and -not $Json) { exit 1 }
  }

  'status' {
    $resolved = Resolve-ServiceName -Names $ServiceName
    $rows = @()
    $hasError = $false
    foreach ($entry in $resolved) {
      if ($entry.class -eq 'error') {
        Write-NucleusWarning "$($entry.displayName) — $($entry.hostEntry.error)"
        $hasError = $true
        continue
      }
      if ($SkipSystemScope -and (Test-ServiceIsSystemScope -ResolvedEntry $entry)) {
        Write-NucleusWarning "$($entry.instanceId) — system-scope operation skipped (elevation unavailable)"
        continue
      }
      $rows += New-StatusRow -ResolvedRow $entry
    }
    Write-Output (Format-StatusTable -Rows $rows)
    if ($hasError -and -not $Json) { exit 1 }
  }

  { @('start', 'stop', 'restart', 'enable', 'disable') -contains $_ } {
    if ($ServiceName.Count -eq 0) {
      throw "missing service name for '$Action'"
    }
    $resolved = Resolve-ServiceName -Names $ServiceName
    $overallExit = 0

    foreach ($entry in $resolved) {
      if ($entry.class -eq 'error') {
        Write-NucleusError "$($entry.displayName) — $($entry.hostEntry.error)"
        $overallExit = 1
        continue
      }

      if ($entry.class -eq 'pseudo') {
        $prefix = Get-NucleusInstanceIdPrefix -HostEntry $entry.hostEntry
        Write-NucleusError "$($entry.registryKey) — no instances found (prefix '$prefix')"
        $overallExit = 1
        continue
      }

      if ($entry.class -eq 'configured') {
        # A named not-loaded id is a failed request; the registry key is an aggregate, so
        # a warning keeps the exit status of the instances that did run.
        if ($ServiceName -contains $entry.instanceId) {
          Write-NucleusError "$($entry.instanceId) — configured but not loaded (run 'nucleus-apply', or start it with the service manager)"
          $overallExit = 1
        } else {
          Write-NucleusWarning "$($entry.instanceId) — configured but not loaded"
        }
        continue
      }

      if ($SkipSystemScope -and (Test-ServiceIsSystemScope -ResolvedEntry $entry)) {
        Write-NucleusWarning "$($entry.instanceId) — system-scope operation skipped (elevation unavailable)"
        continue
      }

      try {
        $result = Invoke-ServiceAction -Action $Action -HostEntry $entry.hostEntry
        if ($result -ne $true) {
          Write-NucleusError "$($entry.instanceId) — action '$Action' failed"
          $overallExit = 1
        } elseif ($Json) {
          $payload = [ordered]@{ version = 1 }
          $payload[$entry.instanceId] = @{ success = $true }
          Write-Output ($payload | ConvertTo-Json -Compress -Depth 3)
        }
      } catch {
        Write-NucleusError "$($entry.instanceId) — $($_.Exception.Message)"
        $overallExit = 1
      }
    }
    if ($overallExit -ne 0) { exit $overallExit }
  }

  'verify' {
    $resolved = Resolve-ServiceName -Names $ServiceName
    $hasInactive = $false
    foreach ($entry in $resolved) {
      if ($entry.class -eq 'error') {
        Write-NucleusWarning "$($entry.displayName) — $($entry.hostEntry.error)"
        $hasInactive = $true
        continue
      }
      if ($entry.class -eq 'pseudo') {
        $prefix = Get-NucleusInstanceIdPrefix -HostEntry $entry.hostEntry
        Write-NucleusWarning "$($entry.registryKey) — no instances found (prefix '$prefix'); nothing to verify"
        continue
      }
      if ($entry.class -eq 'configured') {
        Write-NucleusWarning "$($entry.instanceId) — configured but not loaded (run 'nucleus-apply', or start it with the service manager)"
        $hasInactive = $true
        continue
      }
      if ($SkipSystemScope -and (Test-ServiceIsSystemScope -ResolvedEntry $entry)) {
        Write-NucleusWarning "$($entry.instanceId) — system-scope operation skipped (elevation unavailable)"
        continue
      }
      $status = Get-ServiceStatus -HostEntry $entry.hostEntry
      if ($status.running) {
        $pidStr = if ($status.pid) { " (pid $($status.pid))" } else { '' }
        Write-NucleusInfo -CommandName 'svc' "verify $($entry.instanceId) — active$pidStr"
      } else {
        $diag = if ($status.status) { " ($($status.status))" } else { '' }
        Write-NucleusWarning "$($entry.instanceId) — inactive$diag"
        $hasInactive = $true
      }
    }
    if (-not $hasInactive) {
      Write-NucleusInfo -CommandName 'svc' "all services active"
    }
    if ($hasInactive) { exit 1 }
  }

  'endpoint' {
    if ($ServiceName.Count -eq 0) {
      throw "missing service name for endpoint"
    }
    $svcName = $ServiceName[0]
    $epName  = if ($ServiceName.Count -ge 2) { $ServiceName[1] } else { $null }

    $Registry = [ordered]@{}
    $raw = Get-Content -Raw "$RepoRoot/src/modules/services.json" | ConvertFrom-Json
    if (-not $raw.PSObject.Properties.Name -contains $svcName) {
      Write-NucleusError "$svcName — service not found in registry"
      exit 1
    }
    $entry = $raw.$svcName
    if (-not $entry.PSObject.Properties.Name -contains 'network') {
      Write-NucleusError "$svcName — no network endpoints defined"
      exit 1
    }
    $network = $entry.network

    if ($epName) {
      if (-not $network.PSObject.Properties.Name -contains $epName) {
        Write-NucleusError "$svcName — endpoint '$epName' not found"
        exit 1
      }
      $ep = $network.$epName
      if ($Json) {
        Write-Output ($ep | ConvertTo-Json -Compress)
      } else {
        Write-Output "$($ep.protocol)://$($ep.host):$($ep.port)"
      }
    } else {
      if ($Json) {
        Write-Output ($network | ConvertTo-Json -Compress)
      } else {
        $network.PSObject.Properties | ForEach-Object {
          $ep = $_.Value
          Write-Output "$($_.Name)`t$($ep.protocol)://$($ep.host):$($ep.port)"
        }
      }
    }
  }

  'logs' {
    $logLines = 10
    $logRaw = $false
    $parsedServices = @()
    $i = 0
    while ($i -lt $ServiceName.Count) {
      switch ($ServiceName[$i]) {
        '-n' { $i++; $logLines = [int]::Parse($ServiceName[$i]) }
        '--lines' { $i++; $logLines = [int]::Parse($ServiceName[$i]) }
        '--raw' { $logRaw = $true }
        '--' { $i++; while ($i -lt $ServiceName.Count) { $parsedServices += $ServiceName[$i]; $i++ }; break }
        default { $parsedServices += $ServiceName[$i] }
      }
      $i++
    }
    if ($parsedServices.Count -eq 0) {
      if ($Json) {
        $list = [ordered]@{}
        foreach ($row in (Resolve-ServiceName -Names @())) {
          if ($row.class -eq 'error') { continue }
          $list[$row.instanceId] = @{ capture = Get-CaptureMode -ServiceKey $row.registryKey; hasLogs = Test-ServiceHasLog -ServiceKey $row.registryKey -InstanceId (Get-InstanceArgument -Row $row) }
        }
        Write-Output ($list | ConvertTo-Json -Compress)
      } else {
        Write-Output "Available services:"
        Write-Output ""
        Show-ServiceList
      }
      return
    }
    $hasError = $false
    foreach ($row in (Resolve-ServiceName -Names $parsedServices)) {
      if ($row.class -eq 'error') {
        Write-NucleusError "logs: $($row.displayName) — $($row.hostEntry.error)"
        $hasError = $true
        continue
      }
      if ($row.class -eq 'pseudo') {
        $prefix = Get-NucleusInstanceIdPrefix -HostEntry $row.hostEntry
        Write-NucleusWarning "$($row.registryKey) — no instances found (prefix '$prefix')"
        continue
      }
      Show-ServiceLog -ServiceKey $row.registryKey -Lines $logLines -Raw:$logRaw -InstanceId (Get-InstanceArgument -Row $row) -Configured:($row.class -eq 'configured')
    }
    if ($hasError) { exit 1 }
  }

  'log-paths' {
    $targets = if ($ServiceName.Count -gt 0) { $ServiceName } else { @() }
    $hasError = $false
    foreach ($row in (Resolve-ServiceName -Names $targets)) {
      if ($row.class -eq 'error') {
        Write-NucleusError "log-paths: $($row.displayName) — $($row.hostEntry.error)"
        $hasError = $true
        continue
      }
      if ($row.class -eq 'pseudo') { continue }
      $instanceId = Get-InstanceArgument -Row $row
      $files = Get-ServiceLogFile -ServiceKey $row.registryKey -InstanceId $instanceId
      if ($files.Count -gt 0) { Write-Output ($files -join "`n") }
    }
    if ($hasError) { exit 1 }
  }

  'log-config' {
    $targets = if ($ServiceName.Count -gt 0) { $ServiceName } else { @() }
    $hasError = $false
    # Instance rows share their registry entry's logging configuration, so one config
    # block per registry entry is enough.
    $seen = @()
    foreach ($row in (Resolve-ServiceName -Names $targets)) {
      if ($row.class -eq 'error') {
        Write-NucleusError "log-config: $($row.displayName) — $($row.hostEntry.error)"
        $hasError = $true
        continue
      }
      if ($seen -contains $row.registryKey) { continue }
      $seen += $row.registryKey
      Show-LogConfig -ServiceKey $row.registryKey -JsonOut:$Json
    }
    if ($hasError) { exit 1 }
  }
}
