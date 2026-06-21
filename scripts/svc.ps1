<#
.SYNOPSIS
  Unified service management for Windows (native, scheduled tasks).

.DESCRIPTION
  Provides a uniform CLI for listing, starting, stopping, restarting,
  enabling, and disabling services across Windows service types:
    - native:  standard Windows services (Get-Service, sc.exe)
    - schtask: Scheduled tasks (Get-ScheduledTask etc.)

  Services are defined in src/modules/services.json (the canonical registry).

.PARAMETER Action
  The operation to perform: list, status, start, stop, restart, enable, disable, endpoint.

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

.NOTES
  Environment variables: NUCLEUS_REPO_ROOT.
  Exit codes: 0 on success; non-zero on failure.
#>
[CmdletBinding()]
param(
  [Parameter(Position = 0)]
  [ValidateSet('list', 'status', 'start', 'stop', 'restart', 'enable', 'disable', 'endpoint')]
  [string]$Action,

  [Parameter(Position = 1, ValueFromRemainingArguments = $true)]
  [string[]]$ServiceName = @(),

  [switch]$Json,

  [Alias("h")]
  [switch]$Help
)

$ErrorActionPreference = 'Stop'

if ($Help -or -not $Action) {
  if (-not $Action) { Write-Output "ERROR: missing action (list, status, start, stop, restart, enable, disable)" }
  Get-Help $PSCommandPath -Detailed
  exit 0
}

# ---------------------------------------------------------------------------
# Initialization
# ---------------------------------------------------------------------------

$RepoRoot = if ($env:NUCLEUS_REPO_ROOT) { $env:NUCLEUS_REPO_ROOT } else { (Get-Item $PSScriptRoot).Parent.FullName }
$ServicesJson = Join-Path $RepoRoot "src\modules\services.json"
$Platform = "windows"

# Read and parse registry
if (-not (Test-Path $ServicesJson)) {
  throw "svc: services registry not found at $ServicesJson"
}
$RegistryRaw = Get-Content $ServicesJson -Raw | ConvertFrom-Json -AsHashtable

# Filter to Windows-relevant services
$Registry = @{}
foreach ($svc in $RegistryRaw.Keys) {
  $entry = $RegistryRaw[$svc]
  if ($entry -is [hashtable] -and $entry.platforms.ContainsKey($Platform) -and $entry.platforms[$Platform].type -ne 'omitted') {
    $Registry[$svc] = @{
      displayName = $entry.displayName
      description = $entry.description
      network     = if ($entry.PSObject.Properties.Name -contains 'network') { $entry.network } else { $null }
      platform    = $entry.platforms[$Platform]
    }
  }
}

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
      $plat = $Registry[$key].platform
      if (-not $plat.prefixMatch) {
        $results[$key] = $Registry[$key]
      }
    }
    return $results
  }

  foreach ($name in $Names) {
    if ($Registry.ContainsKey($name)) {
      $plat = $Registry[$name].platform
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
                platform    = @{ type = 'schtask'; taskPath = $taskName }
              }
            }
            if ($matched.Count -eq 0) {
              $results["$name/*"] = @{
                displayName = "$name (no matches)"
                platform    = @{ type = 'schtask'; taskPath = $prefix }
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
        platform    = @{ error = "service not found in registry" }
      }
    }
  }
  return $results
}

# ---------------------------------------------------------------------------
# Status helpers
# ---------------------------------------------------------------------------

function Get-ServiceStatus {
  param(
    [hashtable]$Platform
  )

  $type = $Platform.type

  switch ($type) {
    'native' {
      $svcName = $Platform.service
      try {
        $svc = Get-Service -Name $svcName -ErrorAction Stop
        $running = $svc.Status -eq 'Running'
        $enabled = $svc.StartType -in @('Automatic', 'AutomaticDelayedStart')
        $pid = $null
        if ($running) {
          $pid = (Get-CimInstance -ClassName Win32_Service -Filter "Name='$svcName'" -ErrorAction SilentlyContinue).ProcessId
          if ($pid -eq 0) { $pid = $null }
        }
        return @{
          status  = if ($running) { 'active' } else { 'inactive' }
          running = $running
          enabled = $enabled
          pid     = $pid
        }
      } catch {
        return @{ status = 'not-found'; running = $false; enabled = $false; pid = $null }
      }
    }
    'schtask' {
      $taskPath = $Platform.taskPath
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
    [hashtable]$Platform
  )

  $type = $Platform.type

  switch ($type) {
    'native' {
      $svcName = $Platform.service
      switch ($Action) {
        'status'  { return Get-ServiceStatus -Platform $Platform }
        'start'   { Start-Service -Name $svcName -ErrorAction Stop; return $true }
        'stop'    { Stop-Service -Name $svcName -ErrorAction Stop -Force; return $true }
        'restart' { Restart-Service -Name $svcName -ErrorAction Stop -Force; return $true }
        'enable'  { Set-Service -Name $svcName -StartupType Automatic -ErrorAction Stop; return $true }
        'disable' { Set-Service -Name $svcName -StartupType Disabled -ErrorAction Stop; return $true }
      }
    }
    'schtask' {
      $taskPath = $Platform.taskPath
      $taskName = Split-Path $taskPath -Leaf
      $taskParent = Split-Path $taskPath -Parent
      switch ($Action) {
        'status'  { return Get-ServiceStatus -Platform $Platform }
        'start'   { Start-ScheduledTask -TaskPath $taskParent -TaskName $taskName -ErrorAction Stop; return $true }
        'stop'    { Stop-ScheduledTask -TaskPath $taskParent -TaskName $taskName -ErrorAction Stop; return $true }
        'restart' { Stop-ScheduledTask -TaskPath $taskParent -TaskName $taskName -ErrorAction SilentlyContinue; Start-ScheduledTask -TaskPath $taskParent -TaskName $taskName -ErrorAction Stop; return $true }
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
    $jsonObj = @{ svc_version = '1'; services = @{} }
    foreach ($key in $Results.Keys) {
      if ($key -like 'ERROR:*') { continue }
      $jsonObj.services[$key] = $Results[$key]
    }
    return ($jsonObj | ConvertTo-Json -Depth 3 -Compress)
  }

  $lines = @()
  $lines += "{0,-24} {1,-10} {2,-8} {3}" -f 'Service', 'Status', 'Running', 'PID'
  $lines += '-' * 60

  foreach ($key in $Results.Keys) {
    $info = $Results[$key]
    if ($key -like 'ERROR:*') {
      $realKey = $key -replace '^ERROR:'
      $lines += "{0,-24} {1,-10} {2,-8} {3}" -f $realKey, 'n/a', '-', '-'
    } else {
      $lines += "{0,-24} {1,-10} {2,-8} {3}" -f $key, $info.status, $info.running, ($info.pid -as [int] -or '-')
    }
  }
  return $lines -join "`n"
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
      $status = Get-ServiceStatus -Platform $resolved[$key].platform
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
        Write-Warning "svc: $($resolved[$key].displayName) — $($resolved[$key].platform.error)"
        $hasError = $true
        continue
      }
      $status = Get-ServiceStatus -Platform $resolved[$key].platform
      $results[$key] = $status
    }
    Write-Output (Format-StatusTable -Results $results)
    if ($hasError -and -not $Json) { exit 1 }
  }

  { @('start', 'stop', 'restart', 'enable', 'disable') -contains $_ } {
    if ($ServiceName.Count -eq 0) {
      throw "svc: missing service name for '$Action'"
    }
    $resolved = Resolve-ServiceName -Names $ServiceName
    $overallExit = 0

    foreach ($key in $resolved.Keys) {
      if ($key -like 'ERROR:*') {
        Write-Error "svc: $($resolved[$key].displayName) — service not found in registry"
        $overallExit = 1
        continue
      }

      $plat = $resolved[$key].platform
      if ($plat.prefixMatch) {
        Write-Error "svc: $key — prefix-match services require exact name; use list/status first"
        $overallExit = 1
        continue
      }

      try {
        $result = Invoke-ServiceAction -Action $Action -Platform $plat
        if ($result -ne $true) {
          Write-Error "svc: $key — action '$Action' failed"
          $overallExit = 1
        } elseif ($Json) {
          Write-Output "{`"$key`":{`"success`":true}}"
        }
      } catch {
        Write-Error "svc: $key — $($_.Exception.Message)"
        $overallExit = 1
      }
    }
    if ($overallExit -ne 0) { exit $overallExit }
  }

  'endpoint' {
    if ($ServiceName.Count -eq 0) {
      throw "svc: missing service name for endpoint"
    }
    $svcName = $ServiceName[0]
    $epName  = if ($ServiceName.Count -ge 2) { $ServiceName[1] } else { $null }

    $Registry = [ordered]@{}
    $raw = Get-Content -Raw "$RepoRoot/src/modules/services.json" | ConvertFrom-Json
    if (-not $raw.PSObject.Properties.Name -contains $svcName) {
      Write-Error "svc: $svcName — service not found in registry"
      exit 1
    }
    $entry = $raw.$svcName
    if (-not $entry.PSObject.Properties.Name -contains 'network') {
      Write-Error "svc: $svcName — no network endpoints defined"
      exit 1
    }
    $network = $entry.network

    if ($epName) {
      if (-not $network.PSObject.Properties.Name -contains $epName) {
        Write-Error "svc: $svcName — endpoint '$epName' not found"
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
}
