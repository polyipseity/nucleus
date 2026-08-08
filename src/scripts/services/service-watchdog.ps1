<#
.SYNOPSIS
  Persistent-loop service watchdog for Windows.

.DESCRIPTION
  Detects and restarts nucleus-managed services stuck in a non-running state.
  Reads src/modules/services.json, filters to Windows services, and restarts
  any native SCM service or scheduled task that is not running.
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

$ServicesJson = Join-Path $RepoRoot "src\modules\services.json"
if (-not (Test-Path $ServicesJson)) {
  Write-NucleusInfo "services registry not found at $ServicesJson"
  exit 1
}

$RegistryRaw = Get-Content $ServicesJson -Raw | ConvertFrom-Json -AsHashtable
$NucleusHost = 'Windows'

# ── Filter to watchdog-managed services ────────────────────────────────────
# Exclude: omitted, socket-activated, prefix-match (handled by svc.ps1).
$Services = @()
foreach ($key in $RegistryRaw.Keys) {
  $entry = $RegistryRaw[$key]
  if ($entry -isnot [hashtable]) { continue }
  if (-not $entry.hosts.ContainsKey($NucleusHost)) { continue }

  $hostEntry = $entry.hosts[$NucleusHost]
  if ($hostEntry.type -eq "omitted") { continue }
  if ($hostEntry.socketActivated) { continue }
  if ($hostEntry.prefixMatch) { continue }

  $Services += @{
    key         = $key
    displayName = $entry.displayName
    type        = $hostEntry.type
    service     = $hostEntry.service
    taskPath    = $hostEntry.taskPath
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

# ── Main loop (persistent daemon pattern) ──────────────────────────────────
function Invoke-WatchdogIteration {
  foreach ($svc in $Services) {
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
