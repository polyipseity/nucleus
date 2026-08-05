<#
.SYNOPSIS
  Unified VM management for Windows.

.DESCRIPTION
  Subcommands: setup, list, status, start, stop, upgrade, reset, resize, gc, pack.

  setup:   Build VM images (if needed) and provision VMs.
           Delegates to Invoke-VMSetup.ps1 (phase 1: Packer build,
           phase 2: QEMU start scripts + disk images).
  list:    List VMs from the manifest.
  status:  Show VM configuration (same as list with more detail).
  start:   Start a VM (not yet implemented).
  stop:    Stop a VM (not yet implemented).
  upgrade: Upgrade an Android VM image (not yet implemented on Windows).
  reset:   Reset an Android VM image (not yet implemented on Windows).
  resize:  Grow-only resize of the writable disk (data/<id>.qcow2) to an
           explicit size (e.g. 64GB); pass --allow-shrink to shrink instead.
  gc:      Remove stale VM artifacts. Delegates to Invoke-VMSetup -Gc.
           Default GC preserves disabled VM entries; pass --gc-disabled
           to clear them too.
  pack:    Strip trivially regenerable artifacts (generated start/stop
           scripts, images/<type>.base.qcow2 copies, images/*-build/ + stale
           dot-dirs) so the tree can be copied as-is to another host.
           Dry-run by default; pass --force to perform. Refuses while any
           VM is running.

.PARAMETER Action
  The operation to perform: setup, list, status, start, stop, upgrade, reset, resize, gc, pack.

.PARAMETER SubcommandArgs
  Additional arguments passed after the subcommand (flags, VM names, etc.).

.PARAMETER Help
  Show detailed help.

.EXAMPLE
  .\vm.ps1 setup
  .\vm.ps1 setup --windows-iso C:\ISOs\Win11.iso --headful
  .\vm.ps1 setup --gc
  .\vm.ps1 gc
  .\vm.ps1 gc --gc-disabled
  .\vm.ps1 list
  .\vm.ps1 status
  .\vm.ps1 pack
  .\vm.ps1 pack --force

.NOTES
  Environment variables: NUCLEUS_REPO_ROOT.
  Exit codes: 0 on success; 1 on failure.
#>
[CmdletBinding()]
param(
  [Parameter(Position = 0)]
  [ValidateSet('setup', 'list', 'status', 'start', 'stop', 'upgrade', 'reset', 'resize', 'gc', 'pack')]
  [string]$Action,

  [Parameter(Position = 1, ValueFromRemainingArguments = $true)]
  [string[]]$SubcommandArgs = @(),

  [Alias("h")]
  [switch]$Help
)

# Suppress false positive PSReviewUnusedParameter — $SubcommandArgs IS used below
# (setup flag parsing, status/stop/reset actions).
$null = $SubcommandArgs  # check-suppress:suppression_doc: splatting variable, declared for parameter binding

$ErrorActionPreference = 'Stop'

$modulePath = Join-Path $PSScriptRoot '..\src\hosts\Windows\modules\Format-NucleusOutput.psm1'
Import-Module $modulePath -Force -DisableNameChecking

if ($Help -or -not $Action) {
  if (-not $Action) { Write-NucleusError "missing action (setup, list, status, start, stop, upgrade, reset, resize, gc, pack)" }
  Get-Help $PSCommandPath -Detailed
  exit 0
}

$RepoRoot = if ($env:NUCLEUS_REPO_ROOT) { $env:NUCLEUS_REPO_ROOT } else { (Get-Item $PSScriptRoot).Parent.FullName }
$ManifestPath = Join-Path $RepoRoot 'src\modules\VMs.json'
. (Join-Path $RepoRoot 'src\hosts\Windows\modules\SizeStrings.ps1')

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
      '--gc-disabled' { $invokeArgs['GcDisabled'] = $true }
      '--no-gc-disabled' { $invokeArgs['GcDisabled'] = $false }
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

function Get-VmRunningNameList {
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
  $runningNameList = Get-VmRunningNameList

  # Filter to enabled VMs matching the current host
  $vms = $manifest.VMs | Where-Object {
    $_.enabled -eq $true -and $_.hosts -contains $hostName
  }

  Write-Output "NAME                TYPE           ENABLED    STATE    HOSTS"
  foreach ($vm in $vms) {
    $hostsStr = ($vm.hosts -join ',')
    $state = if ($vm.id -in $runningNameList) { 'running' } else { 'stopped' }
    Write-Output ("{0,-20} {1,-14} {2,-10} {3,-9} {4}" -f $vm.name, $vm.type, $vm.enabled, $state, $hostsStr)
  }
}

function Invoke-VmStatus {
  $manifest = Get-VmManifest
  $hostName = if ($env:NUCLEUS_HOST) { $env:NUCLEUS_HOST } else { 'windows' }
  $runningNameList = Get-VmRunningNameList

  # Filter to enabled VMs matching the current host
  $vms = $manifest.VMs | Where-Object {
    $_.enabled -eq $true -and $_.hosts -contains $hostName
  }

  Write-Output "NAME                TYPE           ENABLED    STATE    HOSTS    CPUS      RAM"
  foreach ($vm in $vms) {
    $hostsStr = ($vm.hosts -join ',')
    $ramBytes = ConvertFrom-SizeString $vm.ram
    $ramGb = [math]::Round($ramBytes / 1000000000, 0)
    $state = if ($vm.id -in $runningNameList) { 'running' } else { 'stopped' }
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
  $startScript = Join-Path -Path $vmDir -ChildPath 'scripts' -AdditionalChildPath "start-$vmName.ps1"

  if (Test-Path -LiteralPath $startScript -PathType Leaf) {
    Write-NucleusInfo "starting VM '$vmName' via generated script..."
    & $startScript
    return
  }

  $manifest = Get-VmManifest
  $vm = $manifest.VMs | Where-Object { $_.id -eq $vmName }
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
  $stopScript = Join-Path -Path $vmDir -ChildPath 'scripts' -AdditionalChildPath "stop-$vmName.ps1"

  if (Test-Path -LiteralPath $stopScript -PathType Leaf) {
    Write-NucleusInfo "stopping VM '$vmName' via generated script..."
    & $stopScript
    return
  }

  $manifest = Get-VmManifest
  $vm = $manifest.VMs | Where-Object { $_.id -eq $vmName }
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

  Resolve-VMGuestCredential -RepoRoot $RepoRoot > $null
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

  Resolve-VMGuestCredential -RepoRoot $RepoRoot > $null
  Write-NucleusInfo "resetting Android VM '$vmName' on Windows..."
  Write-NucleusWarning "Android reset on Windows is not yet fully implemented"
}

function Invoke-VmResize {
  if ($SubcommandArgs.Length -lt 2) {
    Write-NucleusError 'resize requires a VM name and a size (e.g. "nucleus-vm resize NixOS 64GB")'
    exit 1
  }

  $vmName = $SubcommandArgs[0]
  $sizeArg = $SubcommandArgs[1]
  $allowShrink = $false
  for ($i = 2; $i -lt $SubcommandArgs.Length; $i++) {
    switch ($SubcommandArgs[$i]) {
      '--allow-shrink' { $allowShrink = $true }
      default { Write-NucleusWarning "ignoring unknown flag for resize: $($SubcommandArgs[$i])" }
    }
  }

  $manifest = Get-VmManifest
  $vm = $manifest.VMs | Where-Object { $_.id -eq $vmName }
  if (-not $vm) {
    Write-NucleusError "VM '$vmName' not found in manifest"
    exit 1
  }

  $diskBytes = ConvertFrom-SizeString $sizeArg

  $vmDir = if ($env:VM_DIR_OVERRIDE) { $env:VM_DIR_OVERRIDE } else { Join-Path $env:USERPROFILE 'virtual machines' }
  $diskPath = Join-Path -Path $vmDir -ChildPath 'data' -AdditionalChildPath "$vmName.qcow2"
  if (-not (Test-Path -LiteralPath $diskPath -PathType Leaf)) {
    Write-NucleusError "writable disk not found at $diskPath; run 'nucleus-vm setup' first"
    exit 1
  }

  if ($vmName -in (Get-VmRunningNameList)) {
    Write-NucleusError "VM '$vmName' is running; stop it before resizing"
    exit 1
  }

  # Locate qemu-img from the Scoop-managed QEMU installation (or PATH).
  $scoopQemuDir = Join-Path $env:USERPROFILE 'scoop\apps\qemu\current'
  $qemuImg = Join-Path $scoopQemuDir 'qemu-img.exe'
  if (-not (Test-Path $qemuImg)) {
    # check-suppress:suppression_doc: probe whether qemu-img is on PATH; Get-Command throws when absent.
    $qemuImgInPath = Get-Command qemu-img -ErrorAction SilentlyContinue
    if ($qemuImgInPath) {
      $qemuImg = $qemuImgInPath.Source
    } else {
      $qemuImg = $null
    }
  }
  if (-not $qemuImg) {
    Write-NucleusError "qemu-img not found; install QEMU via Scoop (scoop install qemu) or add it to PATH"
    exit 1
  }

  $oldBytes = [long]((& $qemuImg info --output=json $diskPath | Out-String) | ConvertFrom-Json).'virtual-size'
  if ($diskBytes -le $oldBytes -and -not $allowShrink) {
    Write-NucleusError "shrink requires --allow-shrink (current $oldBytes bytes, target $diskBytes bytes)"
    exit 1
  }

  $qemuArgs = @()
  if ($diskBytes -lt $oldBytes) { $qemuArgs += '--shrink' }
  & $qemuImg resize @qemuArgs $diskPath $diskBytes
  if ($LASTEXITCODE -ne 0) {
    Write-NucleusError "failed to resize $diskPath to $diskBytes bytes"
    exit 1
  }

  Write-NucleusInfo "resized '$vmName' disk: $oldBytes -> $diskBytes bytes"
}

function Invoke-VmGc {
  $module = Join-Path $RepoRoot 'src\hosts\Windows\modules\system\Invoke-VMSetup.ps1'
  if (-not (Test-Path $module)) {
    Write-NucleusWarning "Invoke-VMSetup module not found at $module"
    exit 1
  }
  . $module

  $gcDisabled = $false
  foreach ($arg in $SubcommandArgs) {
    switch ($arg) {
      '--gc-disabled' { $gcDisabled = $true }
      '--no-gc-disabled' { $gcDisabled = $false }
      default { Write-NucleusWarning "ignoring unknown flag for gc: $arg" }
    }
  }

  Invoke-VMSetup -RepoRoot $RepoRoot -Gc -GcDisabled:$gcDisabled
}

function Invoke-VmPack {
  $perform = $false
  foreach ($arg in $SubcommandArgs) {
    switch ($arg) {
      '--force' { $perform = $true }
      default { Write-NucleusWarning "ignoring unknown flag for pack: $arg" }
    }
  }

  if (@(Get-VmRunningNameList).Count -gt 0) {
    Write-NucleusError 'cannot pack while a VM is running; stop all VMs first'
    exit 1
  }

  $vmDir = if ($env:VM_DIR_OVERRIDE) { $env:VM_DIR_OVERRIDE } else { Join-Path $env:USERPROFILE 'virtual machines' }
  $imagesDir = Join-Path $vmDir 'images'

  if (-not $perform) {
    Write-NucleusInfo 'pack (dry-run): pass --force to remove regenerable artifacts'
  }

  # Generated start/stop helper scripts (keep pack/unpack wrappers).
  $scriptsDir = Join-Path $vmDir 'scripts'
  if (Test-Path -LiteralPath $scriptsDir -PathType Container) {
    Get-ChildItem -LiteralPath $scriptsDir -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^(start|stop)-.+\\.(sh|ps1)$' } | ForEach-Object {
      Write-NucleusInfo "pack — removing regenerable start/stop script: $($_.FullName)"
      if ($perform) { Remove-Item -LiteralPath $_.FullName -Force }
    }
  }

  if (Test-Path -LiteralPath $imagesDir -PathType Container) {
    # images/<type>.base.qcow2 — trivial cp from the kept prebuilt golden.
    Get-ChildItem -LiteralPath $imagesDir -Filter '*.base.qcow2' -File -ErrorAction SilentlyContinue | ForEach-Object {
      Write-NucleusInfo "pack — removing regenerable base image: $($_.FullName)"
      if ($perform) { Remove-Item -LiteralPath $_.FullName -Force }
    }

    # images/*-build/ + stale dot-dirs (transient Packer junk).
    Get-ChildItem -LiteralPath $imagesDir -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -like '*-build' -or $_.Name -match '^\..+' } | ForEach-Object {
      Write-NucleusInfo "pack — removing transient build directory: $($_.FullName)"
      if ($perform) { Remove-Item -LiteralPath $_.FullName -Recurse -Force }
    }
  }

  Write-NucleusInfo 'pack — summary: stripped regenerable wrappers; payload retained (images, data, descriptors, README)'
  Write-NucleusInfo "pack — next: copy the tree to the target host, then run 'nucleus-vm unpack' or 'nucleus-vm setup' there"
  if (-not $perform) {
    Write-NucleusInfo 'pack — dry-run: nothing was removed; pass --force to perform'
  }
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
  'resize'  { Invoke-VmResize }
  'gc'      { Invoke-VmGc }
  'pack'    { Invoke-VmPack }
}
