<#
.SYNOPSIS
  Persistent-loop service watchdog for Windows.

.DESCRIPTION
  Detects and restarts nucleus-managed services stuck in a non-running state.
  Reads src/modules/services.json, filters to Windows services, and restarts
  any native SCM service or scheduled task that is not running.  A prefix-match
  entry is expanded per instance: every live instance is checked on its own,
  and an instance the user registry declares but Windows does not run is
  reported once per transition instead of being started, because those tasks
  exit 0 by design when their remote is unconfigured.
  Runs indefinitely with 300 s sleep between iterations (persistent daemon
  pattern — launched by scheduled task AtStartup).
  Use -Oneshot to run a single iteration (for manual or CI use).
  Mirrors src/scripts/services/service-watchdog.sh (POSIX counterpart).
#>

param(
  [switch]$Oneshot
)

$ErrorActionPreference = "Stop"

$modulePath = Join-Path $PSScriptRoot '..\..\..\src\platforms\Windows\modules\Format-NucleusOutput.psm1'
Import-Module $modulePath -Force -DisableNameChecking

# ── Resolve repo root ──────────────────────────────────────────────────────
$RepoRoot = if ($env:NUCLEUS_REPO_ROOT) {
  $env:NUCLEUS_REPO_ROOT
} else {
  Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
}

. (Join-Path $RepoRoot 'src\platforms\Windows\modules\Get-NucleusServiceInstance.ps1')

$ServicesJson = Join-Path $RepoRoot "src\modules\services.json"
if (-not (Test-Path $ServicesJson)) {
  Write-NucleusInfo "services registry not found at $ServicesJson"
  exit 1
}

$RegistryRaw = Get-Content $ServicesJson -Raw | ConvertFrom-Json -AsHashtable
$NucleusHost = 'Windows'

# ── Filter to watchdog-managed services ────────────────────────────────────
# Exclude: omitted, socket-activated.  Prefix-match entries are kept and
# expanded per instance during the iteration.
$Services = @()
foreach ($key in $RegistryRaw.Keys) {
  $entry = $RegistryRaw[$key]
  if ($entry -isnot [hashtable]) { continue }
  if (-not $entry.hosts.ContainsKey($NucleusHost)) { continue }

  $hostEntry = $entry.hosts[$NucleusHost]
  if ($hostEntry.type -eq "omitted") { continue }
  if ($hostEntry.socketActivated) { continue }

  $Services += @{
    key         = $key
    displayName = $entry.displayName
    type        = $hostEntry.type
    service     = $hostEntry.service
    taskPath    = $hostEntry.taskPath
    prefixMatch = [bool]$hostEntry.prefixMatch
    hostEntry   = $hostEntry
  }
}

# ── Helper: log restart ────────────────────────────────────────────────────
function Write-RestartLog {
  param([string]$Name, [string]$Reason)
  $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
  $cmd = Get-NucleusCommandName
  Write-Output "[$timestamp] ${cmd}: restarted $Name ($Reason)"
}

# ── Check native services ──────────────────────────────────────────────────
function Test-NativeService {
  param([string]$Key, [string]$DisplayName, [string]$ServiceName)

  try {
    $svc = Get-Service -Name $ServiceName -ErrorAction Stop
    if ($svc.Status -eq "Running") { return }

    $status = $svc.Status.ToString().ToLower()
    Restart-Service -Name $ServiceName -Force -ErrorAction Stop
    Write-RestartLog -Name $DisplayName -Reason $status
  } catch {
    Write-NucleusInfo "error checking $Key ($ServiceName): $_"
  }
}

# ── Check scheduled tasks ──────────────────────────────────────────────────
function Test-ScheduledTask {
  param([string]$Key, [string]$DisplayName, [string]$TaskPath)

  try {
    $taskName = Split-Path $TaskPath -Leaf
    $taskParent = Split-Path $TaskPath -Parent
    $task = Get-ScheduledTask -TaskPath $taskParent -TaskName $taskName -ErrorAction Stop

    if ($task.State -eq "Running") { return }

    $status = $task.State.ToString().ToLower()
    Stop-ScheduledTask -TaskPath $taskParent -TaskName $taskName -ErrorAction SilentlyContinue  # check-suppress:suppression_doc: best-effort stop before restart -- task may not be running
    Start-ScheduledTask -TaskPath $taskParent -TaskName $taskName -ErrorAction Stop
    Write-RestartLog -Name $DisplayName -Reason $status
  } catch {
    Write-NucleusInfo "error checking $Key ($TaskPath): $_"
  }
}

# ── Helper: not-loaded markers ─────────────────────────────────────────────
# WHY: the loop ticks every 300 s, so a declared-but-absent mount is reported on
# its transition only; the marker is cleared as soon as the instance is live.
# The marker is keyed by the full instance id, matching the POSIX watchdog.
function Get-NotLoadedMarkerPath {
  param([string]$InstanceId)
  $stateDir = Join-Path (Join-Path $env:ProgramData 'nucleus') 'state\service-stats'
  # Task ids contain separators, which are invalid in a file name.
  $safe = $InstanceId -replace '[\\/:*?"<>|]', '_'
  return Join-Path $stateDir "$safe.notloaded"
}

function Write-NotLoadedLog {
  param([string]$Key, [string]$InstanceId)
  $marker = Get-NotLoadedMarkerPath -InstanceId $InstanceId
  if (Test-Path -Path $marker -PathType Leaf) { return }
  New-Item -Path (Split-Path -Parent $marker) -ItemType Directory -Force > $null
  New-Item -Path $marker -ItemType File -Force > $null
  $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
  $cmd = Get-NucleusCommandName
  Write-Output "[$timestamp] ${cmd}: $Key $InstanceId configured but not loaded (run 'nucleus-svc status $Key' or 'nucleus-apply')"
}

function Clear-NotLoadedMarker {
  param([string]$InstanceId)
  $marker = Get-NotLoadedMarkerPath -InstanceId $InstanceId
  if (Test-Path -Path $marker -PathType Leaf) { Remove-Item -Path $marker -Force }
}

# ── Main loop (persistent daemon pattern) ──────────────────────────────────
function Invoke-WatchdogIteration {
  foreach ($svc in $Services) {
    if ($svc.prefixMatch) {
      $instances = @(Get-NucleusPrefixInstanceList -HostEntry $svc.hostEntry)
      foreach ($instance in $instances) {
        Test-ScheduledTask -Key $instance -DisplayName "$($svc.displayName) ($instance)" -TaskPath $instance
        Clear-NotLoadedMarker -InstanceId $instance
      }
      $configured = @(Get-NucleusConfiguredInstanceList -HostEntry $svc.hostEntry -RepoRoot $RepoRoot)
      foreach ($expected in $configured) {
        if ($instances -contains $expected) { continue }
        Write-NotLoadedLog -Key $svc.key -InstanceId $expected
      }
      continue
    }

    switch ($svc.type) {
      "native" {
        Test-NativeService -Key $svc.key -DisplayName $svc.displayName -ServiceName $svc.service
      }
      "schtask" {
        Test-ScheduledTask -Key $svc.key -DisplayName $svc.displayName -TaskPath $svc.taskPath
      }
      default {
        Write-NucleusInfo "unsupported type $($svc.type) for $($svc.key)"
      }
    }
  }
}

if ($Oneshot) {
  Invoke-WatchdogIteration
} else {
  while ($true) {
    Invoke-WatchdogIteration
    Start-Sleep -Seconds 300
  }
}
