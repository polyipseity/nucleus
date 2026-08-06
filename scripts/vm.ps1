<#
.SYNOPSIS
  Unified VM management for Windows.

.DESCRIPTION
  Subcommands: setup, sync, list, status, start, stop, upgrade, reset, resize, gc, pack, unpack.

  sync:    Refresh VM config (descriptors, start/stop scripts). Non-destructive.
  setup:   Full provision: config sync + image build + disk setup.
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
  unpack:  Regenerate per-platform VM artifacts (start/stop scripts +
           pack/unpack wrappers) from the <id>.vm.json descriptors in the
           VM directory, after copying a packed tree to this host.
           Complements pack; re-renders start/stop scripts (PowerShell) for
           every descriptor, enabled or disabled. Data files are consumed
           as-is. Pass --dry-run to preview.

.PARAMETER Action
  The operation to perform: setup, list, status, start, stop, upgrade, reset, resize, gc, pack, unpack.

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
  .\vm.ps1 unpack
  .\vm.ps1 unpack --dry-run

.NOTES
  Environment variables: NUCLEUS_REPO_ROOT.
  Exit codes: 0 on success; 1 on failure.
#>
[CmdletBinding()]
param(
  [Parameter(Position = 0)]
  [ValidateSet('setup', 'sync', 'list', 'status', 'start', 'stop', 'upgrade', 'reset', 'resize', 'gc', 'pack', 'unpack')]
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
  if (-not $Action) { Write-NucleusError "missing action (setup, sync, list, status, start, stop, upgrade, reset, resize, gc, pack, unpack)" }
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

function Invoke-VmSync {
  $module = Join-Path $RepoRoot 'src\hosts\Windows\modules\system\Invoke-VMSetup.ps1'
  if (-not (Test-Path $module)) {
    Write-NucleusWarning "Invoke-VMSetup module not found at $module"
    exit 1
  }
  . $module

  $invokeArgs = @{ RepoRoot = $RepoRoot }
  $i = 0
  while ($i -lt $SubcommandArgs.Length) {
    switch ($SubcommandArgs[$i]) {
      '--vm-dir-override' {
        $i++
        if ($i -ge $SubcommandArgs.Length) {
          Write-NucleusError '--vm-dir-override requires a path argument'
          exit 1
        }
        $env:VM_DIR_OVERRIDE = $SubcommandArgs[$i]
      }
      '--dry-run' { $invokeArgs['DryRun'] = $true }
      '--help' {
        Get-Help $PSCommandPath -Detailed
        exit 0
      }
      default {
        Write-NucleusWarning "ignoring unknown flag for sync: $($SubcommandArgs[$i])"
      }
    }
    $i++
  }

  Invoke-VMSync @invokeArgs
}

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
  $module = Join-Path $RepoRoot 'src\hosts\Windows\modules\system\Invoke-VMSetup.ps1'
  if (-not (Test-Path $module)) {
    return @()
  }
  . $module
  return @(Get-VmRunningProcessNames)
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
    Get-ChildItem -LiteralPath $scriptsDir -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^(start|stop)-.+\.(sh|ps1)$' } | ForEach-Object {
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

function Invoke-VmUnpack {
  $perform = $true
  foreach ($arg in $SubcommandArgs) {
    switch ($arg) {
      '--dry-run' { $perform = $false }
      default { Write-NucleusWarning "ignoring unknown flag for unpack: $arg" }
    }
  }

  $vmDir = if ($env:VM_DIR_OVERRIDE) { $env:VM_DIR_OVERRIDE } else { Join-Path $env:USERPROFILE 'virtual machines' }
  $templatesDir = Join-Path $RepoRoot 'src\vms\templates'
  $scriptsDir = Join-Path $vmDir 'scripts'

  if (-not $perform) {
    Write-NucleusInfo 'unpack (dry-run): pass --force to regenerate artifacts'
  }

  $descriptors = @(Get-ChildItem -LiteralPath $vmDir -Filter '*.vm.json' -File -ErrorAction SilentlyContinue)
  if ($descriptors.Count -eq 0) {
    Write-NucleusInfo "unpack — no descriptors found in $vmDir; run 'nucleus-vm setup' to write them"
    return
  }

  foreach ($descriptor in $descriptors) {
    $vmDoc = Get-Content -LiteralPath $descriptor.FullName -Raw | ConvertFrom-Json
    if (-not $vmDoc.id) {
      Write-NucleusWarning "unpack — descriptor without an id, skipping: $($descriptor.FullName)"
      continue
    }
    $vmId = [string]$vmDoc.id
    $vmType = [string]$vmDoc.type

    # Start script (PowerShell) — the cross-host dispatcher for the
    # non-Android case; the shared Android start script otherwise.
    $startPs1Path = Join-Path $scriptsDir "start-$vmId.ps1"
    $startShPath = Join-Path $scriptsDir "start-$vmId.sh"
    $stopPs1Path = Join-Path $scriptsDir "stop-$vmId.ps1"

    if ($vmType -eq 'Android') {
      $androidTemplate = Join-Path $RepoRoot 'src\scripts\vms\start-android-vm.ps1'
      if (Test-Path -LiteralPath $androidTemplate -PathType Leaf) {
        $ramBytes = ConvertFrom-SizeString $vmDoc.ram
        $hostFwds = @($vmDoc.portForwards | ForEach-Object { "hostfwd=tcp::$($_.hostPort)-:$($_.guestPort)" }) -join ','
        $content = (Get-Content -LiteralPath $androidTemplate -Raw)
        $content = $content.Replace('__ANDROID_CPU_COUNT__', [string]$vmDoc.cpus)
        $content = $content.Replace('__ANDROID_RAM_BYTES__', "$ramBytes" + 'B')
        $content = $content.Replace('__ANDROID_SYSTEM_IMAGE__', [string]$vmDoc.Android.systemImage)
        $content = $content.Replace('__ANDROID_USERDATA_IMAGE__', [string]$vmDoc.Android.userdataImage)
        $content = $content.Replace('__ANDROID_GSI_IMAGE__', [string]$vmDoc.Android.gsiImage)
        $content = $content.Replace('__HOSTFWDS__', $hostFwds)
        Write-VmUnpackFile -Path $startPs1Path -Content $content -Perform $perform
      } else {
        Write-NucleusWarning "unpack — shared Android start script not found: $androidTemplate"
      }
    } else {
      # Windows QEMU start scripts mirror Invoke-VMSetup.ps1 rendering: the
      # cross-host templates stay single-source and all tokens come from the
      # descriptor JSON document.
      $hostFwds = @($vmDoc.portForwards | ForEach-Object { "hostfwd=tcp::$($_.hostPort)-:$($_.guestPort)" }) -join ','
      $ramBytes = ConvertFrom-SizeString $vmDoc.ram
      # Relocatable writable-disk path: data/<id>.qcow2 relative to the VM
      # tree root (the templates cd/Push-Location before invoking QEMU).
      $diskPath = Join-Path 'data' "$vmId.qcow2"
      $qemuArch = if ($env:PROCESSOR_ARCHITECTURE -match 'ARM64|ARM') { 'aarch64' } else { 'x86_64' }
      $qemuSystem = Join-Path $env:USERPROFILE "scoop\apps\qemu\current\qemu-system-$qemuArch.exe"
      $machine = if ($qemuArch -eq 'x86_64') { 'q35' } else { 'virt' }

      $startPs1Template = Join-Path $templatesDir 'start-windows.ps1'
      if (Test-Path -LiteralPath $startPs1Template -PathType Leaf) {
        $content = (Get-Content -LiteralPath $startPs1Template -Raw)
        $content = $content.Replace('__QEMU_SYSTEM__', $qemuSystem)
        $content = $content.Replace('__VM_NAME__', $vmId)
        $content = $content.Replace('__VM_DISPLAY__', [string]$vmDoc.name)
        $content = $content.Replace('__MACHINE__', $machine)
        $content = $content.Replace('__CPU__', 'host')
        $content = $content.Replace('__CPUS__', [string]$vmDoc.cpus)
        $content = $content.Replace('__RAM_BYTES__', [string]$ramBytes)
        $content = $content.Replace('__DISK_PATH__', $diskPath)
        $content = $content.Replace('__HOSTFWDS__', $hostFwds)
        $content = $content.Replace('__VGA__', 'std')
        $content = $content.Replace('__DISPLAY_BACKEND__', 'sdl')
        $content = $content.Replace('__VIRTIOFS_ARGS__', '')
        Write-VmUnpackFile -Path $startPs1Path -Content $content -Perform $perform
      } else {
        Write-NucleusWarning "unpack — start-windows.ps1 template not found: $startPs1Template"
      }

      $startShTemplate = Join-Path $templatesDir 'start-windows-host.sh'
      if (Test-Path -LiteralPath $startShTemplate -PathType Leaf) {
        $content = (Get-Content -LiteralPath $startShTemplate -Raw)
        $content = $content.Replace('__QEMU_SYSTEM__', $qemuSystem)
        $content = $content.Replace('__VM_NAME__', $vmId)
        $content = $content.Replace('__VM_DISPLAY__', [string]$vmDoc.name)
        $content = $content.Replace('__MACHINE__', $machine)
        $content = $content.Replace('__CPU__', 'host')
        $content = $content.Replace('__CPUS__', [string]$vmDoc.cpus)
        $content = $content.Replace('__RAM_BYTES__', [string]$ramBytes)
        $content = $content.Replace('__DISK_PATH__', $diskPath)
        $content = $content.Replace('__HOSTFWDS__', $hostFwds)
        $content = $content.Replace('__VGA__', 'std')
        $content = $content.Replace('__DISPLAY_BACKEND__', 'sdl')
        Write-VmUnpackFile -Path $startShPath -Content $content -Perform $perform
      } else {
        Write-NucleusWarning "unpack — start-windows-host.sh template not found: $startShTemplate"
      }
    }

    # Stop script (PowerShell).  The .sh variant is not rendered for
    # windows-qemu hosts (stop-posix.sh dispatches to tart/utmctl/virsh only),
    # mirroring the POSIX lib.
    $stopPs1Template = Join-Path $templatesDir 'stop-host.ps1'
    if (Test-Path -LiteralPath $stopPs1Template -PathType Leaf) {
      $content = (Get-Content -LiteralPath $stopPs1Template -Raw)
      $content = $content.Replace('__HOST_KIND__', 'windows-qemu')
      $content = $content.Replace('__VM_NAME__', $vmId)
      Write-VmUnpackFile -Path $stopPs1Path -Content $content -Perform $perform
    } else {
      Write-NucleusWarning "unpack — stop-host.ps1 template not found: $stopPs1Template"
    }
  }

  # Refresh the pack/unpack wrappers (BOTH variants) for the whole tree.
  if ($perform) {
    if (-not (Test-Path -LiteralPath $scriptsDir)) { New-Item -ItemType Directory -Path $scriptsDir -Force | Out-Null }
  }
  Write-VmUnpackFile -Path (Join-Path $scriptsDir 'pack.sh') -Content @'
#!/usr/bin/env bash
set -euo pipefail
exec nucleus-vm pack "$@"
'@ -Perform $perform
  Write-VmUnpackFile -Path (Join-Path $scriptsDir 'unpack.sh') -Content @'
#!/usr/bin/env bash
set -euo pipefail
exec nucleus-vm unpack "$@"
'@ -Perform $perform
  Write-VmUnpackFile -Path (Join-Path $scriptsDir 'pack.ps1') -Content @'
# Generated by nucleus-vm setup — pack.ps1. Delegates to nucleus-vm pack.
& nucleus-vm pack @args
exit $LASTEXITCODE
'@ -Perform $perform
  Write-VmUnpackFile -Path (Join-Path $scriptsDir 'unpack.ps1') -Content @'
# Generated by nucleus-vm setup — unpack.ps1. Delegates to nucleus-vm unpack.
& nucleus-vm unpack @args
exit $LASTEXITCODE
'@ -Perform $perform

  Write-NucleusInfo "unpack — summary: regenerated wrappers for $($descriptors.Count) descriptor(s) in $vmDir"
  if (-not $perform) {
    Write-NucleusInfo 'unpack — dry-run: nothing was regenerated; pass --force to perform'
  }
}

# Write-VmUnpackFile PATH CONTENT PERFORM
#   Writes PATH unless PERFORM is false (dry-run prints the planned write).
function Write-VmUnpackFile {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$Content,
    [Parameter(Mandatory = $true)][bool]$Perform
  )
  if ($Perform) {
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    Set-Content -LiteralPath $Path -Value $Content -Encoding UTF8
    Write-NucleusInfo "unpack — wrote $Path"
  } else {
    Write-NucleusInfo "unpack (dry-run): would write $Path"
  }
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------

switch ($Action) {
  'setup'   { Invoke-VmSetup }
  'sync'    { Invoke-VmSync }
  'list'    { Invoke-VmList }
  'status'  { Invoke-VmStatus }
  'start'   { Invoke-VmStart }
  'stop'    { Invoke-VmStop }
  'upgrade' { Invoke-VmUpgrade }
  'reset'   { Invoke-VmReset }
  'resize'  { Invoke-VmResize }
  'gc'      { Invoke-VmGc }
  'pack'    { Invoke-VmPack }
  'unpack'  { Invoke-VmUnpack }
}
