<#
.SYNOPSIS
  View service logs from the nucleus logging system on Windows.

.DESCRIPTION
  Displays service logs from file-based log directories or Windows Event Log.
  File-based services (discord-music-rpc, cloud-mount, litellm, replica-sync)
  store logs under Get-NucleusLogDir\{service}\combined.log.
  Native Windows services (ollama, rdp, ssh-agent, sshd) log to Event Log.

  NOTE: This script is Windows-only. Use logs.sh on macOS/NixOS.

.PARAMETER Service
  One or more service names to show logs for. Omit to list available services.

.PARAMETER Lines
  Number of recent lines to show (default: 10).

.PARAMETER Paths
  Print log file paths instead of showing content.

.PARAMETER Raw
  Skip sanitization, show raw output.

.PARAMETER Json
  Output in JSON format (list mode).

.PARAMETER Help
  Show this help message.

.EXAMPLE
  .\logs.ps1
  List services with available log output.

.EXAMPLE
  .\logs.ps1 litellm
  Follow litellm service logs.

.EXAMPLE
  .\logs.ps1 litellm -Lines 50
  Show last 50 lines from litellm logs.

.EXAMPLE
  .\logs.ps1 --Paths
  Print all log file paths.

.EXAMPLE
  .\logs.ps1 ollama -Lines 20
  Show last 20 Event Log entries for ollama.

.NOTES
  Exit codes: 0 on success; non-zero on failure.
#>
[CmdletBinding()]
param(
  [Parameter(Position = 0)]
  [string[]]$Service = @(),

  [Alias("n")]
  [Parameter()]
  [int]$Lines = 10,

  [Parameter()]
  [switch]$Paths,

  [Parameter()]
  [switch]$Raw,

  [Parameter()]
  [switch]$Json,

  [Alias("h")]
  [Parameter()]
  [switch]$Help
)

$ErrorActionPreference = 'Stop'

if ($Help) {
  Get-Help $PSCommandPath -Detailed
  return
}

# --- Resolve repo root and services.json ---
$repoRoot = if ($env:NUCLEUS_REPO_ROOT) { $env:NUCLEUS_REPO_ROOT } else { Join-Path $PSScriptRoot ".." }
$servicesJson = Join-Path $repoRoot "src" "modules" "services.json"
if (-not (Test-Path $servicesJson)) {
  Write-Error "logs: services.json not found at $servicesJson"
  exit 1
}

# --- Load log management helpers ---
$logMgmtPath = Join-Path $repoRoot "src" "hosts" "Windows" "modules" "Invoke-LogManagement.ps1"
if (Test-Path $logMgmtPath) {
  . $logMgmtPath
}

# Fallback log dir functions if Invoke-LogManagement.ps1 is not available
if (-not (Get-Command "Get-NucleusLogDir" -ErrorAction SilentlyContinue)) {
  function Get-NucleusLogDir {
    if ($env:NUCLEUS_LOG_DIR) { return $env:NUCLEUS_LOG_DIR }
    return Join-Path $env:LOCALAPPDATA "nucleus" "logs"
  }
  function Get-NucleusSystemLogDir {
    if ($env:NUCLEUS_SYSTEM_LOG_DIR) { return $env:NUCLEUS_SYSTEM_LOG_DIR }
    return Join-Path $env:ProgramData "nucleus" "logs"
  }
  function ConvertTo-SanitizedText {
    param([string]$Text)
    if (-not $Text) { return "" }
    # Strip ANSI escape sequences, carriage returns, and control chars (except tab/newline)
    $Text = $Text -replace '\e\[[0-9;]*[a-zA-Z]', ''
    $Text = $Text -replace '\r', ''
    $Text = $Text -replace '[^\x09\x20-\x7E\x0A]', ''
    return $Text
  }
}

# --- Parse services.json ---
$services = Get-Content $servicesJson -Raw | ConvertFrom-Json

# Get list of Windows services
function Get-PlatformServices {
  $result = @()
  foreach ($prop in $services.PSObject.Properties) {
    if ($prop.Name -like '$*') { continue }
    $svc = $prop.Value
    if ($svc.platforms -and $svc.platforms.windows) {
      $result += $prop.Name
    }
  }
  return $result | Sort-Object
}

# Get capture mode for a service
function Get-CaptureMode {
  param([string]$ServiceName)
  $svc = $services.$ServiceName
  if (-not $svc) { return "none" }

  # Platform-specific logging overrides top-level
  if ($svc.platforms -and $svc.platforms.windows -and $svc.platforms.windows.logging -and $svc.platforms.windows.logging.capture) {
    return $svc.platforms.windows.logging.capture
  }
  if ($svc.logging -and $svc.logging.capture) {
    return $svc.logging.capture
  }
  return "all"
}

# Get Event Log provider for a service
function Get-EventLogProvider {
  param([string]$ServiceName)
  $svc = $services.$ServiceName
  if (-not $svc) { return $null }

  if ($svc.logging -and $svc.logging.eventLog -and $svc.logging.eventLog.provider) {
    return $svc.logging.eventLog.provider
  }
  if ($svc.platforms -and $svc.platforms.windows -and $svc.platforms.windows.logging -and $svc.platforms.windows.logging.eventLog -and $svc.platforms.windows.logging.eventLog.provider) {
    return $svc.platforms.windows.logging.eventLog.provider
  }
  return $null
}

# Get the Windows service name from services.json
function Get-WindowsServiceName {
  param([string]$ServiceName)
  $svc = $services.$ServiceName
  if (-not $svc) { return $null }
  if ($svc.platforms -and $svc.platforms.windows -and $svc.platforms.windows.service) {
    return $svc.platforms.windows.service
  }
  return $null
}

# Find log files for a service
function Get-ServiceLogFiles {
  param([string]$ServiceName)
  $files = @()
  $userDir = Join-Path (Get-NucleusLogDir) $ServiceName
  $systemDir = Join-Path (Get-NucleusSystemLogDir) $ServiceName

  if (Test-Path $userDir) {
    $files += Get-ChildItem -Path $userDir -Filter "*.log" -File | Select-Object -ExpandProperty FullName
  }
  if (Test-Path $systemDir) {
    $files += Get-ChildItem -Path $systemDir -Filter "*.log" -File | Select-Object -ExpandProperty FullName
  }
  return $files
}

# Check if a service has accessible logs
function Test-ServiceHasLogs {
  param([string]$ServiceName)
  $capture = Get-CaptureMode $ServiceName

  # File-based check
  if ($capture -ne "none") {
    $files = Get-ServiceLogFiles $ServiceName
    if ($files.Count -gt 0) { return $true }
  }

  # Event Log check
  $provider = Get-EventLogProvider $ServiceName
  if ($provider) {
    try {
      $events = Get-WinEvent -ProviderName $provider -MaxEvents 1 -ErrorAction Stop
      if ($events) { return $true }
    } catch {
      # Provider may not exist or no events yet
    }
  }

  return $false
}

# --- Display functions ---

function Show-FileLogs {
  param([string]$ServiceName)
  $files = Get-ServiceLogFiles $ServiceName

  if ($files.Count -eq 0) {
    Write-Warning "logs: $ServiceName — no log files found"
    return
  }

  if ($Paths) {
    $files | ForEach-Object { Write-Output $_ }
    return
  }

  foreach ($file in $files) {
    $content = Get-Content -Path $file -Tail $Lines -Wait
    if (-not $Raw) {
      $content | ForEach-Object { Write-Output (ConvertTo-SanitizedText $_) }
    } else {
      $content | ForEach-Object { Write-Output $_ }
    }
  }
}

function Show-EventLog {
  param([string]$ServiceName)
  $provider = Get-EventLogProvider $ServiceName

  if (-not $provider) {
    Write-Warning "logs: $ServiceName — no Event Log provider configured"
    return
  }

  try {
    $events = Get-WinEvent -ProviderName $provider -MaxEvents $Lines -ErrorAction Stop | Sort-Object TimeCreated -Descending
    foreach ($event in $events) {
      $text = "[$($event.TimeCreated.ToString('yyyy-MM-dd HH:mm:ss'))] [$($event.LevelDisplayName)] $($event.Message)"
      if (-not $Raw) {
        Write-Output (ConvertTo-SanitizedText $text)
      } else {
        Write-Output $text
      }
    }
  } catch {
    Write-Warning "logs: $ServiceName — Event Log query failed: $_"
  }
}

function Show-ServiceLogs {
  param([string]$ServiceName)
  $capture = Get-CaptureMode $ServiceName
  $provider = Get-EventLogProvider $ServiceName

  if ($provider) {
    Show-EventLog $ServiceName
  } elseif ($capture -ne "none") {
    Show-FileLogs $ServiceName
  } else {
    Write-Warning "logs: $ServiceName — no log source configured (capture=none, no Event Log)"
  }
}

function Show-Paths {
  $services_list = Get-PlatformServices
  if ($Service.Count -gt 0) {
    $services_list = $Service | Where-Object { $_ -in $services_list }
  }
  foreach ($svc in $services_list) {
    $files = Get-ServiceLogFiles $svc
    if ($files.Count -gt 0) {
      $files | ForEach-Object { Write-Output $_ }
    }
  }
}

function Show-ServiceList {
  $services_list = Get-PlatformServices
  if ($Json) {
    $services_list | ConvertTo-Json -Compress
    return
  }

  Write-Output "Available services:`n"
  foreach ($svc in $services_list) {
    $capture = Get-CaptureMode $svc
    $hasLogs = Test-ServiceHasLogs $svc
    $status = if ($hasLogs) { "" } else { " (no logs yet)" }
    Write-Output ("  {0,-25} capture={1,-7}{2}" -f $svc, $capture, $status)
  }
}

# --- Main ---
if ($Paths) {
  Show-Paths
  exit 0
}

if ($Service.Count -eq 0) {
  Show-ServiceList
  exit 0
}

# Validate and show logs for requested services
$platformServices = Get-PlatformServices
foreach ($svc in $Service) {
  if ($svc -notin $platformServices) {
    Write-Error "logs: unknown service '$svc' for Windows platform"
    exit 1
  }
  Show-ServiceLogs $svc
}
