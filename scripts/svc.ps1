<#
.SYNOPSIS
  Unified service management and log inspection for Windows (native, scheduled tasks).

.DESCRIPTION
  Provides a uniform CLI for listing, starting, stopping, restarting,
  enabling, disabling, and inspecting logs of services across Windows
  service types:
    - native:  standard Windows services (Get-Service, sc.exe)
    - schtask: Scheduled tasks (Get-ScheduledTask etc.)

  Services are defined in src/modules/services.json (the canonical registry).

.PARAMETER Action
  The operation to perform: list, status, start, stop, restart, enable, disable,
  endpoint, logs, log-paths, log-config.

.PARAMETER ServiceName
  One or more service names to target (required for start/stop/restart/enable/disable;
  optional for status — defaults to all). For endpoint, first is service name, second (optional) is endpoint name.

.PARAMETER Json
  Output machine-readable JSON instead of formatted tables.

.PARAMETER Help
  Show detailed help.

.EXAMPLE
  .\svc.ps1 list
  .\svc.ps1 status ollama,sshd
  .\svc.ps1 start ollama
  .\svc.ps1 restart jellyfin
  .\svc.ps1 endpoint jellyfin http
  .\svc.ps1 list -Json
  .\svc.ps1 logs
  .\svc.ps1 logs ollama -n 50
  .\svc.ps1 logs jellyfin --raw
  .\svc.ps1 log-paths ollama
  .\svc.ps1 log-config ollama,jellyfin
  .\svc.ps1 log-config ollama -Json

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

if ($Help -or -not $Action) {
  if (-not $Action) { Write-NucleusError "missing action (list, status, start, stop, restart, enable, disable, verify, endpoint, logs, log-paths, log-config)" }
  Get-Help $PSCommandPath -Detailed
  exit 0
}

# ---------------------------------------------------------------------------
# Initialization
# ---------------------------------------------------------------------------

$RepoRoot = if ($env:NUCLEUS_REPO_ROOT) { $env:NUCLEUS_REPO_ROOT } else { (Get-Item $PSScriptRoot).Parent.FullName }
$ServicesJson = Join-Path $RepoRoot "src\modules\services.json"
$NucleusHost = 'Windows'

# ── Self-elevation ──────────────────────────────────────────────────────────────
# Set when elevation was requested but could not be obtained (UAC cancelled /
# no admin). In that case system-domain entries are skipped with a warning
# rather than failing the whole run (rule-2 "cannot escalate" branch).
$SkipSystemDomain = $false

# System-domain operations (native services, scheduled tasks) require admin.
# When the caller is not elevated, re-exec via RunAs so the operation can
# actually run. If elevation is impossible (UAC cancelled / no admin), warn and
# skip only the system-domain entries rather than failing the whole run.
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
    Write-NucleusWarning "svc: elevation unavailable (UAC cancelled or no admin) — system-domain operations will be skipped"
    # Continue un-elevated: user-domain operations still work; system-domain
    # entries are skipped below via $SkipSystemDomain.
    $SkipSystemDomain = $true
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

# ---------------------------------------------------------------------------
# Resolve service names (expand prefix matches)
# ---------------------------------------------------------------------------

function Resolve-ServiceName {
  param(
    [string[]]$Names
  )

  $results = @{}

  if ($Names.Count -eq 0) {
    # Return all non-prefix services
    foreach ($key in $Registry.Keys) {
      $plat = $Registry[$key].hostEntry
      if (-not $plat.prefixMatch) {
        $results[$key] = $Registry[$key]
      }
    }
    return $results
  }

  foreach ($name in $Names) {
    if ($Registry.ContainsKey($name)) {
      $plat = $Registry[$name].hostEntry
      if ($plat.prefixMatch) {
        # Expand prefix match
        $prefix = $plat.service
        switch ($plat.type) {
          'schtask' {
            $matched = Get-ScheduledTask | Where-Object { $_.TaskPath -like "*$prefix*" -or $_.TaskName -like "$prefix*" }
            foreach ($t in $matched) {
              $taskName = if ($t.TaskPath -eq '\') { $t.TaskName } else { "$($t.TaskPath)$($t.TaskName)" }
              $results["$name/$($t.TaskName)"] = @{
                displayName = "$name ($($t.TaskName))"
                hostEntry   = @{ type = 'schtask'; taskPath = $taskName }
              }
            }
            if ($matched.Count -eq 0) {
              $results["$name/*"] = @{
                displayName = "$name (no matches)"
                hostEntry   = @{ type = 'schtask'; taskPath = $prefix }
              }
            }
          }
        }
      } else {
        $results[$name] = $Registry[$name]
      }
    } else {
      $results["ERROR:$name"] = @{
        displayName = $name
        hostEntry   = @{ error = "service not found in registry" }
      }
    }
  }
  return $results
}

# Returns $true when the resolved registry entry is a system-domain service
# (requires admin). Used to skip such entries when elevation is unavailable.
function Test-ServiceIsSystemDomain {
  param(
    [hashtable]$ResolvedEntry
  )
  $plat = $ResolvedEntry.hostEntry
  if ($null -eq $plat -or -not $plat.ContainsKey('domain')) { return $false }
  return $plat.domain -eq 'system'
}

# ---------------------------------------------------------------------------
# Status helpers
# ---------------------------------------------------------------------------

function Get-ServiceStatus {
  param(
    [hashtable]$HostEntry
  )

  $type = $HostEntry.type

  switch ($type) {
    'native' {
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
    'schtask' {
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
    'native' {
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
    'schtask' {
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

# ---------------------------------------------------------------------------
# Action implementations
# ---------------------------------------------------------------------------

function Format-StatusTable {
  param(
    [hashtable]$Results
  )

  if ($Json) {
    $jsonObj = @{ version = 1; services = @{} }
    foreach ($key in $Results.Keys) {
      if ($key -like 'ERROR:*') { continue }
      $jsonObj.services[$key] = $Results[$key]
    }
    return ($jsonObj | ConvertTo-Json -Depth 3 -Compress)
  }

  $lines = @()
  $lines += "{0,-20} {1,-24} {2,-10} {3,-8} {4}" -f 'ID', 'Name', 'Status', 'Running', 'PID'
  $lines += '-' * 80

  foreach ($key in $Results.Keys) {
    $info = $Results[$key]
    if ($key -like 'ERROR:*') {
      $realKey = $key -replace '^ERROR:'
      $lines += "{0,-20} {1,-24} {2,-10} {3,-8} {4}" -f $realKey, '', 'n/a', '-', '-'
    } else {
      $lines += "{0,-20} {1,-24} {2,-10} {3,-8} {4}" -f $key, $info.displayName, $info.status, $info.running, ($info.pid ?? '-')
    }
  }
  return $lines -join "`n"
}

# ---------------------------------------------------------------------------
# Log helpers
# ---------------------------------------------------------------------------

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
  param([string]$ServiceKey)
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
  return $dirs
}

function Get-ServiceLogFile {
  param([string]$ServiceKey)
  $files = @()
  foreach ($dir in (Get-ServiceLogDirList -ServiceKey $ServiceKey)) {
    if (Test-Path -LiteralPath $dir -PathType Container) {
      # check-suppress:suppression_doc: probe -- log dir may be empty; empty result handled.
      $files += Get-ChildItem -LiteralPath $dir -Recurse -Filter '*.log' -File -ErrorAction SilentlyContinue |
        Select-Object -ExpandProperty FullName
    }
  }
  return $files | Sort-Object
}

function Test-ServiceHasLog {
  param([string]$ServiceKey)
  $capture = Get-CaptureMode -ServiceKey $ServiceKey
  if ($capture -ne 'none') {
    $files = Get-ServiceLogFile -ServiceKey $ServiceKey
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
  param([string]$ServiceKey, [int]$Lines = 10, [switch]$Raw)
  $files = Get-ServiceLogFile -ServiceKey $ServiceKey
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
  param([string]$ServiceKey, [int]$Lines = 10, [switch]$Raw)
  if (Show-EventLog -ServiceKey $ServiceKey -Lines $Lines -Raw:$Raw) { return }
  $capture = Get-CaptureMode -ServiceKey $ServiceKey
  if ($capture -ne 'none') {
    if (-not (Show-FileLog -ServiceKey $ServiceKey -Lines $Lines -Raw:$Raw)) {
      Write-NucleusWarning "$ServiceKey — no log files found"
    }
  } else {
    Write-NucleusWarning "$ServiceKey — capture disabled"
  }
}

function Show-ServiceList {
  foreach ($svc in (Get-HostService)) {
    $capture = Get-CaptureMode -ServiceKey $svc
    $hasLog = Test-ServiceHasLog -ServiceKey $svc
    Write-Output ("  {0,-25} capture={1,-7}{2}" -f $svc, $capture, $(if (-not $hasLog) { ' (no logs yet)' } else { '' }))
  }
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
    $results = @{}
    $hasError = $false
    foreach ($key in $resolved.Keys) {
      if ($key -like 'ERROR:*') {
        $hasError = $true
        continue
      }
      if ($SkipSystemDomain -and (Test-ServiceIsSystemDomain -ResolvedEntry $resolved[$key])) {
        Write-NucleusWarning "$key — system-domain operation skipped (elevation unavailable)"
        continue
      }
      $status = Get-ServiceStatus -HostEntry $resolved[$key].hostEntry
      $status.displayName = $resolved[$key].displayName
      $results[$key] = $status
    }
    Write-Output (Format-StatusTable -Results $results)
    if ($hasError -and -not $Json) { exit 1 }
  }

  'status' {
    $resolved = Resolve-ServiceName -Names $ServiceName
    $results = @{}
    $hasError = $false
    foreach ($key in $resolved.Keys) {
      if ($key -like 'ERROR:*') {
        Write-NucleusWarning "$($resolved[$key].displayName) — $($resolved[$key].hostEntry.error)"
        $hasError = $true
        continue
      }
      if ($SkipSystemDomain -and (Test-ServiceIsSystemDomain -ResolvedEntry $resolved[$key])) {
        Write-NucleusWarning "$key — system-domain operation skipped (elevation unavailable)"
        continue
      }
      $status = Get-ServiceStatus -HostEntry $resolved[$key].hostEntry
      $status.displayName = $resolved[$key].displayName
      $results[$key] = $status
    }
    Write-Output (Format-StatusTable -Results $results)
    if ($hasError -and -not $Json) { exit 1 }
  }

  { @('start', 'stop', 'restart', 'enable', 'disable') -contains $_ } {
    if ($ServiceName.Count -eq 0) {
      throw "missing service name for '$Action'"
    }
    $resolved = Resolve-ServiceName -Names $ServiceName
    $overallExit = 0

    foreach ($key in $resolved.Keys) {
      if ($key -like 'ERROR:*') {
        Write-NucleusError "$($resolved[$key].displayName) — service not found in registry"
        $overallExit = 1
        continue
      }

      if ($SkipSystemDomain -and (Test-ServiceIsSystemDomain -ResolvedEntry $resolved[$key])) {
        Write-NucleusWarning "$key — system-domain operation skipped (elevation unavailable)"
        continue
      }

      $plat = $resolved[$key].hostEntry
      if ($plat.prefixMatch) {
        Write-NucleusError "$key — prefix-match services require exact name; use list/status first"
        $overallExit = 1
        continue
      }

      try {
        $result = Invoke-ServiceAction -Action $Action -HostEntry $plat
        if ($result -ne $true) {
          Write-NucleusError "$key — action '$Action' failed"
          $overallExit = 1
        } elseif ($Json) {
          Write-Output (@{ version = 1; $key = @{ success = $true } } | ConvertTo-Json -Compress -Depth 3)
        }
      } catch {
        Write-NucleusError "$key — $($_.Exception.Message)"
        $overallExit = 1
      }
    }
    if ($overallExit -ne 0) { exit $overallExit }
  }

  'verify' {
    $resolved = Resolve-ServiceName -Names $ServiceName
    $hasInactive = $false
    foreach ($key in $resolved.Keys) {
      if ($key -like 'ERROR:*') {
        Write-NucleusWarning "$($resolved[$key].displayName) — $($resolved[$key].hostEntry.error)"
        $hasInactive = $true
        continue
      }
      if ($SkipSystemDomain -and (Test-ServiceIsSystemDomain -ResolvedEntry $resolved[$key])) {
        Write-NucleusWarning "$key — system-domain operation skipped (elevation unavailable)"
        continue
      }
      $status = Get-ServiceStatus -HostEntry $resolved[$key].hostEntry
      if ($status.running) {
        $pidStr = if ($status.pid) { " (pid $($status.pid))" } else { '' }
        Write-NucleusInfo -CommandName 'svc' "verify $key — active$pidStr"
      } else {
        $diag = if ($status.status) { " ($($status.status))" } else { '' }
        Write-NucleusWarning "$key — inactive$diag"
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
        foreach ($svc in (Get-HostService)) {
          $list[$svc] = @{ capture = Get-CaptureMode -ServiceKey $svc; hasLogs = Test-ServiceHasLog -ServiceKey $svc }
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
    foreach ($svc in $parsedServices) {
      if (-not $Registry.ContainsKey($svc)) {
        Write-NucleusError "unknown service '$svc'"
        $hasError = $true
        continue
      }
      Show-ServiceLog -ServiceKey $svc -Lines $logLines -Raw:$logRaw
    }
    if ($hasError) { exit 1 }
  }

  'log-paths' {
    $targets = if ($ServiceName.Count -gt 0) { $ServiceName } else { Get-HostService }
    $hasError = $false
    foreach ($svc in $targets) {
      if (-not $Registry.ContainsKey($svc)) {
        Write-NucleusError "unknown service '$svc'"
        $hasError = $true
        continue
      }
      $files = Get-ServiceLogFile -ServiceKey $svc
      if ($files.Count -gt 0) { Write-Output ($files -join "`n") }
    }
    if ($hasError) { exit 1 }
  }

  'log-config' {
    $targets = if ($ServiceName.Count -gt 0) { $ServiceName } else { Get-HostService }
    $hasError = $false
    foreach ($svc in $targets) {
      if (-not $Registry.ContainsKey($svc)) {
        Write-NucleusError "unknown service '$svc'"
        $hasError = $true
        continue
      }
      Show-LogConfig -ServiceKey $svc -JsonOut:$Json
    }
    if ($hasError) { exit 1 }
  }
}
