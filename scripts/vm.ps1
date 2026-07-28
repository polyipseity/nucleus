<#
.SYNOPSIS
  Unified VM management for Windows.

.DESCRIPTION
  Subcommands: setup, list, status, start, stop, upgrade, reset, gc.

  setup:   Build VM images (if needed) and provision VMs.
           Delegates to Invoke-VMSetup.ps1 (phase 1: Packer build,
           phase 2: QEMU start scripts + disk images).
  list:    List VMs from the manifest.
  status:  Show VM configuration (same as list with more detail).
  start:   Start a VM (not yet implemented).
  stop:    Stop a VM (not yet implemented).
  upgrade: Upgrade an Android VM image (not yet implemented on Windows).
  reset:   Reset an Android VM image (not yet implemented on Windows).
  gc:      Remove stale VM artifacts. Delegates to Invoke-VMSetup -Gc.

.PARAMETER Action
  The operation to perform: setup, list, status, start, stop, upgrade, reset, gc.

.PARAMETER SubcommandArgs
  Additional arguments passed after the subcommand (flags, VM names, etc.).

.PARAMETER Help
  Show detailed help.

.EXAMPLE
  .\vm.ps1 setup
  .\vm.ps1 setup --windows-iso C:\ISOs\Win11.iso --headful
  .\vm.ps1 setup --gc
  .\vm.ps1 list
  .\vm.ps1 status
  .\vm.ps1 gc

.NOTES
  Environment variables: NUCLEUS_REPO_ROOT.
  Exit codes: 0 on success; 1 on failure.
#>
[CmdletBinding()]
param(
  [Parameter(Position = 0)]
  [ValidateSet('setup', 'list', 'status', 'start', 'stop', 'upgrade', 'reset', 'gc')]
  [string]$Action,

  [Parameter(Position = 1, ValueFromRemainingArguments = $true)]
  [string[]]$SubcommandArgs = @(),

  [Alias("h")]
  [switch]$Help
)

# Suppress false positive PSReviewUnusedParameter — $SubcommandArgs IS used below
# (setup flag parsing, status/stop/reset actions).
$null = $SubcommandArgs

$ErrorActionPreference = 'Stop'

$modulePath = Join-Path $PSScriptRoot '..\src\hosts\Windows\modules\Format-NucleusOutput.psm1'
Import-Module $modulePath -Force -DisableNameChecking

if ($Help -or -not $Action) {
  if (-not $Action) { Write-NucleusError "missing action (setup, list, status, start, stop, upgrade, reset, gc)" }
  Get-Help $PSCommandPath -Detailed
  exit 0
}

$RepoRoot = if ($env:NUCLEUS_REPO_ROOT) { $env:NUCLEUS_REPO_ROOT } else { (Get-Item $PSScriptRoot).Parent.FullName }
$ManifestPath = Join-Path $RepoRoot 'src\modules\VMs.json'

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function Get-VmManifest {
  if (-not (Test-Path $ManifestPath)) {
    Write-NucleusError "VM manifest not found at $ManifestPath"
    exit 1
  }
  return Get-Content $ManifestPath -Raw | ConvertFrom-Json
}

# ---------------------------------------------------------------------------
# Subcommand implementations
# ---------------------------------------------------------------------------

function Invoke-VmSetup {
  $module = Join-Path $RepoRoot 'src\hosts\Windows\modules\system\Invoke-VMSetup.ps1'
  if (-not (Test-Path $module)) {
    Write-NucleusWarning "Invoke-VMSetup module not found at $module"
    exit 1
  }
  . $module

  $invokeArgs = @{ RepoRoot = $RepoRoot }

  # Parse SubcommandArgs for setup-specific flags
  $i = 0
  while ($i -lt $SubcommandArgs.Length) {
    switch ($SubcommandArgs[$i]) {
      '--windows-iso' {
        $i++
        if ($i -ge $SubcommandArgs.Length) {
          Write-NucleusError '--windows-iso requires a path argument'
          exit 1
        }
        $invokeArgs['WindowsIso'] = $SubcommandArgs[$i]
      }
      '--windows-iso-source' {
        $i++
        if ($i -ge $SubcommandArgs.Length) {
          Write-NucleusError '--windows-iso-source requires an argument'
          exit 1
        }
        $invokeArgs['WindowsIsoSource'] = $SubcommandArgs[$i]
      }
      '--windows-iso-retries' {
        $i++
        if ($i -ge $SubcommandArgs.Length) {
          Write-NucleusError '--windows-iso-retries requires a number argument'
          exit 1
        }
        $invokeArgs['WindowsIsoRetries'] = [int]$SubcommandArgs[$i]
      }
      '--accelerator' {
        $i++
        if ($i -ge $SubcommandArgs.Length) {
          Write-NucleusError '--accelerator requires an argument'
          exit 1
        }
        $invokeArgs['Accelerator'] = $SubcommandArgs[$i]
      }
      '--headful' { $invokeArgs['Headful'] = $true }
      '--no-headful' { $invokeArgs['Headful'] = $false }
      '--vm-dir-override' {
        $i++
        if ($i -ge $SubcommandArgs.Length) {
          Write-NucleusError '--vm-dir-override requires a path argument'
          exit 1
        }
        $env:VM_DIR_OVERRIDE = $SubcommandArgs[$i]
      }
      '--dry-run' { $invokeArgs['DryRun'] = $true }
      '--gc' { $invokeArgs['Gc'] = $true }
      '--no-gc' { $invokeArgs['Gc'] = $false }
      '--help' {
        Get-Help $PSCommandPath -Detailed
        exit 0
      }
      default {
        Write-NucleusWarning "ignoring unknown flag for setup: $($SubcommandArgs[$i])"
      }
    }
    $i++
  }

  Invoke-VMSetup @invokeArgs
}

function Get-VmRunningNames {
  # Detect running VMs from QEMU processes (Windows uses QEMU).
  # Matches process command lines containing -name qemu-<vmname>.
  $running = @()
  $procs = Get-CimInstance Win32_Process -Filter "Name = 'qemu-system-x86_64w.exe'" -ErrorAction SilentlyContinue  # check-suppress:suppression_doc: VM may not be running; failure to find processes is expected
  foreach ($p in $procs) {
    if ($p.CommandLine -match '-name\s+(?:qemu-)?(\S+)') {
      $running += $Matches[1]
    }
  }
  return $running
}

function Invoke-VmList {
  $manifest = Get-VmManifest
  $hostName = if ($env:NUCLEUS_HOST) { $env:NUCLEUS_HOST } else { 'windows' }
  $runningNames = Get-VmRunningNames

  # Filter to enabled VMs matching the current host
  $vms = $manifest.VMs | Where-Object {
    $_.enabled -eq $true -and (
      -not $_.hosts -or $_.hosts.Count -eq 0 -or $_.hosts -contains $hostName
    )
  }

  Write-Output "NAME                TYPE           ENABLED    STATE    HOSTS"
  foreach ($vm in $vms) {
    $hostsStr = if ($vm.hosts) { ($vm.hosts -join ',') } else { 'all' }
    $state = if ($vm.name -in $runningNames) { 'running' } else { 'stopped' }
    Write-Output ("{0,-20} {1,-14} {2,-10} {3,-9} {4}" -f $vm.name, $vm.type, $vm.enabled, $state, $hostsStr)
  }
}

function Invoke-VmStatus {
  $manifest = Get-VmManifest
  $hostName = if ($env:NUCLEUS_HOST) { $env:NUCLEUS_HOST } else { 'windows' }
  $runningNames = Get-VmRunningNames

  # Filter to enabled VMs matching the current host
  $vms = $manifest.VMs | Where-Object {
    $_.enabled -eq $true -and (
      -not $_.hosts -or $_.hosts.Count -eq 0 -or $_.hosts -contains $hostName
    )
  }

  Write-Output "NAME                TYPE           ENABLED    STATE    HOSTS    CPUS      RAM"
  foreach ($vm in $vms) {
    $hostsStr = if ($vm.hosts) { ($vm.hosts -join ',') } else { 'all' }
    $ramGb = [math]::Round($vm.ramBytes / 1GB, 0)
    $state = if ($vm.name -in $runningNames) { 'running' } else { 'stopped' }
    Write-Output ("{0,-20} {1,-14} {2,-10} {3,-9} {4,-9} {5,-9} {6}" -f $vm.name, $vm.type, $vm.enabled, $state, $hostsStr, $vm.cpus, "${ramGb}G")
  }
}

function Invoke-VmStart {
  if ($SubcommandArgs.Length -eq 0) {
    Write-NucleusError 'start requires a VM name'
    exit 1
  }

  $vmName = $SubcommandArgs[0]
  $vmDir = if ($env:VM_DIR_OVERRIDE) { $env:VM_DIR_OVERRIDE } else { Join-Path $env:USERPROFILE 'virtual machines' }
  $startScript = Join-Path $vmDir 'scripts' "start-$vmName.ps1"

  if (Test-Path -LiteralPath $startScript -PathType Leaf) {
    Write-NucleusInfo "starting VM '$vmName' via generated script..."
    & $startScript
    return
  }

  $manifest = Get-VmManifest
  $vm = $manifest.VMs | Where-Object { $_.name -eq $vmName }
  if (-not $vm) {
    Write-NucleusError "VM '$vmName' not found in manifest"
    exit 1
  }

  Write-NucleusWarning "start script not found at $startScript; run 'nucleus-vm setup' first"
  exit 1
}

function Invoke-VmStop {
  if ($SubcommandArgs.Length -eq 0) {
    Write-NucleusError 'stop requires a VM name'
    exit 1
  }

  $vmName = $SubcommandArgs[0]
  $vmDir = if ($env:VM_DIR_OVERRIDE) { $env:VM_DIR_OVERRIDE } else { Join-Path $env:USERPROFILE 'virtual machines' }
  $stopScript = Join-Path $vmDir 'scripts' "stop-$vmName.ps1"

  if (Test-Path -LiteralPath $stopScript -PathType Leaf) {
    Write-NucleusInfo "stopping VM '$vmName' via generated script..."
    & $stopScript
    return
  }

  $manifest = Get-VmManifest
  $vm = $manifest.VMs | Where-Object { $_.name -eq $vmName }
  if (-not $vm) {
    Write-NucleusError "VM '$vmName' not found in manifest"
    exit 1
  }

  # Fallback: try to find and kill the QEMU process
  # check-suppress:suppression_doc: VM may not have a running process; expected path
  $qemuProc = Get-Process -Name 'qemu-system-*' -ErrorAction SilentlyContinue | Where-Object {
    $_.CommandLine -match $vmName
  }
  if ($qemuProc) {
    Write-NucleusInfo "stopping QEMU process for VM '$vmName'..."
    $qemuProc | Stop-Process -Force
    return
  }

  Write-NucleusWarning "stop script not found at $stopScript and no running QEMU process found for '$vmName'"
  Write-NucleusWarning "run 'nucleus-vm setup' to generate stop scripts, or stop the VM manually"
  exit 1
}

function Invoke-VmUpgrade {
  if ($SubcommandArgs.Length -eq 0) {
    Write-NucleusError 'upgrade requires a VM name'
    exit 1
  }

  $vmName = $SubcommandArgs[0]
  $module = Join-Path $RepoRoot 'src\hosts\Windows\modules\system\Invoke-VMSetup.ps1'
  if (-not (Test-Path $module)) {
    Write-NucleusError "Invoke-VMSetup module not found at $module"
    exit 1
  }
  . $module

  Resolve-VMGuestCredential -RepoRoot $RepoRoot | Out-Null
  Write-NucleusInfo "upgrading Android VM '$vmName' on Windows..."
  Write-NucleusWarning "Android upgrade on Windows is not yet fully implemented"
}

function Invoke-VmReset {
  if ($SubcommandArgs.Length -eq 0) {
    Write-NucleusError 'reset requires a VM name'
    exit 1
  }

  $vmName = $SubcommandArgs[0]
  $module = Join-Path $RepoRoot 'src\hosts\Windows\modules\system\Invoke-VMSetup.ps1'
  if (-not (Test-Path $module)) {
    Write-NucleusError "Invoke-VMSetup module not found at $module"
    exit 1
  }
  . $module

  Resolve-VMGuestCredential -RepoRoot $RepoRoot | Out-Null
  Write-NucleusInfo "resetting Android VM '$vmName' on Windows..."
  Write-NucleusWarning "Android reset on Windows is not yet fully implemented"
}

function Invoke-VmGc {
  $module = Join-Path $RepoRoot 'src\hosts\Windows\modules\system\Invoke-VMSetup.ps1'
  if (-not (Test-Path $module)) {
    Write-NucleusWarning "Invoke-VMSetup module not found at $module"
    exit 1
  }
  . $module
  Invoke-VMSetup -RepoRoot $RepoRoot -Gc
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------

switch ($Action) {
  'setup'   { Invoke-VmSetup }
  'list'    { Invoke-VmList }
  'status'  { Invoke-VmStatus }
  'start'   { Invoke-VmStart }
  'stop'    { Invoke-VmStop }
  'upgrade' { Invoke-VmUpgrade }
  'reset'   { Invoke-VmReset }
  'gc'      { Invoke-VmGc }
}
