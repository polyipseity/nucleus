<#
.SYNOPSIS
  Unified VM management for Windows.

.DESCRIPTION
  Subcommands: setup, sync, build-system, list, status, start, stop, upgrade, reset, android-config, inject, resize, gc, pack, unpack.

  setup:   Full provision, delegating to Invoke-VMSetup.ps1 (phase 1 Packer build,
           phase 2 QEMU start scripts + disk images).
  sync:    Refresh VM config (descriptors, start/stop scripts). Non-destructive.
  build-system: Build/rebuild a single type's system image (src/<type>/system image.qcow2).
  inject:   Re-run in-place disk injection for one VM (--force recreates the data disk; destructive).
  list:    List VMs from the manifest.
  status:  Show VM configuration (same as list with more detail).
  reset:   Factory-reset an Android VM userdata disk (data/<id>.qcow2).
  android-config: Android post-provision (recovery, GApps, ADB keys, Magisk, root, fake Wi-Fi).
    Flags (after VM name; omit all flags to print the manual):
      --gapps               Sideload MindTheGapps in recovery (enter fastboot first).
      --adb-keys            Install host ~/.android/adbkey.pub into guest adb_keys.
      --magisk              Install Magisk on booted Lineage (patch boot, flash, Magisk su).
      --root                Enable rooted debugging (dev options, persist.sys.root_access).
      --fake-wifi           Create wlan0 via virt_wifi on eth0 (requires Magisk su).
      --fake-wifi-revert    Remove persisted fake Wi-Fi and restore eth0.
  resize:  Grow-only resize of the writable disk (data/<id>.qcow2); pass --allow-shrink to shrink.
  gc:      Remove stale VM artifacts. Default GC preserves disabled VM entries; pass
           --gc-disabled to clear them too.
  pack:    Strip trivially regenerable artifacts so the tree copies as-is to another
           host. Dry-run by default; pass --force to perform. Refuses while any VM runs.
  unpack:  Regenerate per-platform VM artifacts from the <id>.vm.json descriptors after
           copying a packed tree here. Pass --dry-run to preview.

  General flags:
    --accept-gsi-license      Accept the Android GSI license.
    --no-accept-gsi-license   Do not accept the Android GSI license (default).

.PARAMETER Action
  The operation to perform: setup, sync, build-system, list, status, start, stop, upgrade, reset, android-config, inject, resize, gc, pack, unpack.

.NOTES
  Environment variables: NUCLEUS_REPO_ROOT.
  Exit codes: 0 on success; 1 on failure.
#>

[CmdletBinding(PositionalBinding = $false)]
param(
  [ValidateSet('setup', 'sync', 'build-system', 'list', 'status', 'start', 'stop', 'upgrade', 'reset', 'android-config', 'inject', 'resize', 'gc', 'pack', 'unpack')]
  [string]$Action,

  [Parameter(ValueFromRemainingArguments = $true)]
  [string[]]$SubcommandArgs = @(),

  [Alias("h")]
  [switch]$Help,

  [Alias('windows-iso')]
  [string]$WindowsIso,

  [Alias('windows-iso-source')]
  [string]$WindowsIsoSource,

  [Alias('windows-iso-retries')]
  [string]$WindowsIsoRetries,

  [string]$Accelerator,

  [Alias('vm-dir-override')]
  [string]$VmDirOverride,

  [Alias('mido-patch-file')]
  [string]$MidoPatchFile,

  [Alias('mido-script')]
  [string]$MidoScript,

  [string]$RepoRoot,

  [switch]$Json,

  [Alias('dry-run')]
  [switch]$DryRun,

  [switch]$Gc,

  [Alias('no-gc')]
  [switch]$NoGc,

  [Alias('gc-disabled')]
  [switch]$GcDisabled,

  [Alias('no-gc-disabled')]
  [switch]$NoGcDisabled,

  [Alias('gc-data')]
  [switch]$GcData,

  [Alias('no-gc-data')]
  [switch]$NoGcData,

  [switch]$Force,

  [Alias('allow-shrink')]
  [switch]$AllowShrink,

  [Alias('accept-gsi-license')]
  [switch]$AcceptGsiLicense,

  [Alias('no-accept-gsi-license')]
  [switch]$NoAcceptGsiLicense,

  [switch]$Headful,

  [Alias('no-headful')]
  [switch]$NoHeadful,

  [switch]$Gapps,

  [Alias('adb-keys')]
  [switch]$AdbKeys,

  [switch]$Magisk,

  [switch]$Root,

  [Alias('fake-wifi')]
  [switch]$FakeWifi,

  [Alias('fake-wifi-revert')]
  [switch]$FakeWifiRevert
)

. (Join-Path $PSScriptRoot '..\src\scripts\lib\pwsh-guard.ps1')
Assert-NucleusPowerShell -Minimum '7.0'

# Suppress false positive PSReviewUnusedParameter: $SubcommandArgs IS used below
# (setup flag parsing, status/stop/reset actions).
$null = $SubcommandArgs  # check-suppress:suppression_doc: splatting variable, declared for parameter binding
# check-suppress:suppression_doc: script-scope params read inside subcommand functions; PSSA PSReviewUnusedParameter cannot see nested-function reads.
$null = @(
  $WindowsIso, $WindowsIsoSource, $WindowsIsoRetries, $Accelerator,
  $MidoPatchFile, $MidoScript, $Json, $DryRun, $Gc, $NoGc, $GcDisabled,
  $NoGcDisabled, $GcData, $NoGcData, $Force, $AllowShrink, $AcceptGsiLicense,
  $NoAcceptGsiLicense, $Headful, $NoHeadful, $Gapps, $AdbKeys, $Magisk, $Root,
  $FakeWifi, $FakeWifiRevert
)

$ErrorActionPreference = 'Stop'

$cliFlagsModulePath = Join-Path $PSScriptRoot '../src/scripts/lib/nucleus-cli-flags.ps1'
. $cliFlagsModulePath
$SubcommandArgs = @(Resolve-NucleusArgument -Arguments $SubcommandArgs -CommandPath $PSCommandPath -CommandName 'vm' -Subcommand $Action -BoundParameters $PSBoundParameters)
# WHY: PositionalBinding is off so `--flag` reaches the resolver instead of filling the action slot.
# The subcommand is the first leftover token that is not a flag.
$SubcommandArgs = @($SubcommandArgs | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
if ([string]::IsNullOrWhiteSpace($Action) -and $SubcommandArgs.Count -gt 0) { $Action = [string]$SubcommandArgs[0]; $SubcommandArgs = @($SubcommandArgs | Select-Object -Skip 1) }

$modulePath = Join-Path $PSScriptRoot '..\src\platforms\Windows\modules\Format-NucleusOutput.psm1'
Import-Module $modulePath -Force -DisableNameChecking

if ($Help) {
  Get-Help $PSCommandPath -Detailed
  exit 0
}

# A missing action is an error, matching vm.sh (message on stderr, exit 1): a run
# that performed nothing must not read as success. The action list is the twin's,
# in the twin's order rather than this file's ValidateSet order, so both platforms
# report the same set.
if (-not $Action) {
  Write-NucleusError "missing action (setup, sync, build-system, list, status, start, stop, upgrade, reset, android-config, inject, gc, resize, pack, unpack)"
  exit 1
}

if (-not [string]::IsNullOrWhiteSpace($RepoRoot)) {
  $RepoRoot = (Resolve-Path -LiteralPath $RepoRoot -ErrorAction Stop).Path
} elseif ($env:NUCLEUS_REPO_ROOT) {
  $RepoRoot = $env:NUCLEUS_REPO_ROOT
} else {
  $RepoRoot = (Get-Item $PSScriptRoot).Parent.FullName
}
$ManifestPath = Join-Path $RepoRoot 'src\modules\vms\VMs.json'
if (-not $env:NUCLEUS_REPO_ROOT) { $env:NUCLEUS_REPO_ROOT = $RepoRoot }
if (-not [string]::IsNullOrWhiteSpace($VmDirOverride)) { $env:VM_DIR_OVERRIDE = $VmDirOverride }
. (Join-Path $RepoRoot 'src\platforms\Windows\modules\Get-NucleusHostPlatform.ps1')
. (Join-Path $RepoRoot 'src\platforms\Windows\modules\SizeStrings.ps1')

function Get-VMManifest {
  if (-not (Test-Path $ManifestPath)) {
    Write-NucleusError "VM manifest not found at $ManifestPath"
    exit 1
  }
  return Get-Content $ManifestPath -Raw | ConvertFrom-Json
}

function Assert-NoExtraVMPositionalArg {
  param(
    [Parameter(Mandatory)]
    [string]$ActionName,
    [Parameter(Mandatory)]
    [int]$Consumed
  )
  $extras = @($SubcommandArgs | Select-Object -Skip $Consumed | Where-Object { $_ -notlike '-*' })
  if ($extras.Count -gt 0) {
    Write-NucleusWarning "vm ${ActionName}: ignoring unexpected positional argument(s): $($extras -join ', ')"
  }
}

function Invoke-VMSync {
  $module = Join-Path $RepoRoot 'src\platforms\Windows\modules\system\Invoke-VMSetup.ps1'
  if (-not (Test-Path $module)) {
    Write-NucleusWarning "Invoke-VMSetup module not found at $module"
    exit 1
  }

  $invokeArgs = @{ RepoRoot = $RepoRoot }
  if (-not [string]::IsNullOrWhiteSpace($VmDirOverride)) {
    $env:VM_DIR_OVERRIDE = $VmDirOverride
  }
  if ($DryRun.IsPresent) { $invokeArgs['DryRun'] = $true }
  if ($Help.IsPresent) {
    Get-Help $PSCommandPath -Detailed
    exit 0
  }

  & {
    param(
      [string]$ModulePath,
      [hashtable]$InvokeArgs
    )
    . $ModulePath
    Invoke-VMSync @InvokeArgs
  } -ModulePath $module -InvokeArgs $invokeArgs
}

function Invoke-VMBuildSystem {
  if ($SubcommandArgs.Length -eq 0) {
    Write-NucleusError 'build-system requires a VM type (e.g. "nucleus-vm build-system NixOS")'
    exit 1
  }
  $vmType = $SubcommandArgs[0]
  Assert-NoExtraVMPositionalArg -ActionName 'build-system' -Consumed 1

  $module = Join-Path $RepoRoot 'src\platforms\Windows\modules\system\Invoke-VMSetup.ps1'
  if (-not (Test-Path $module)) {
    Write-NucleusWarning "Invoke-VMSetup module not found at $module"
    exit 1
  }

  $invokeArgs = @{ RepoRoot = $RepoRoot; Type = $vmType }

  if (-not [string]::IsNullOrWhiteSpace($VmDirOverride)) {
    $env:VM_DIR_OVERRIDE = $VmDirOverride
  }
  if ($DryRun.IsPresent) { $invokeArgs['DryRun'] = $true }
  if ($Help.IsPresent) {
    Get-Help $PSCommandPath -Detailed
    exit 0
  }

  & {
    param(
      [string]$ModulePath,
      [hashtable]$InvokeArgs
    )
    . $ModulePath
    Invoke-VMSystemBuild @InvokeArgs
  } -ModulePath $module -InvokeArgs $invokeArgs
}

function Invoke-VMInject {
  if ($SubcommandArgs.Length -eq 0) {
    Write-NucleusError 'inject requires a VM id (e.g. "nucleus-vm inject NixOS")'
    exit 1
  }
  $vmName = $SubcommandArgs[0]
  Assert-NoExtraVMPositionalArg -ActionName 'inject' -Consumed 1
  $force = $Force.IsPresent

  $manifest = Get-VMManifest
  $vm = $manifest.VMs | Where-Object { $_.id -eq $vmName }
  if (-not $vm) {
    Write-NucleusError "VM '$vmName' not found in manifest"
    exit 1
  }

  if ($vmName -in (Get-VMRunningIdList)) {
    Write-NucleusError "VM '$vmName' is running; stop it before injecting"
    exit 1
  }

  $vmSh = Join-Path $RepoRoot 'scripts\vm.sh'
  if (-not (Test-Path -LiteralPath $vmSh -PathType Leaf)) {
    Write-NucleusError "vm.sh not found at $vmSh"
    exit 1
  }
  $injectArgs = @('inject', $vmName)
  if ($force) { $injectArgs += '--force' }
  & bash $vmSh @injectArgs
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}

function Invoke-VMSetup {
  $module = Join-Path $RepoRoot 'src\platforms\Windows\modules\system\Invoke-VMSetup.ps1'
  if (-not (Test-Path $module)) {
    Write-NucleusWarning "Invoke-VMSetup module not found at $module"
    exit 1
  }

  $invokeArgs = @{ RepoRoot = $RepoRoot }

  if (-not [string]::IsNullOrWhiteSpace($WindowsIso)) { $invokeArgs['WindowsIso'] = $WindowsIso }
  if (-not [string]::IsNullOrWhiteSpace($WindowsIsoSource)) { $invokeArgs['WindowsIsoSource'] = $WindowsIsoSource }
  if (-not [string]::IsNullOrWhiteSpace($WindowsIsoRetries)) { $invokeArgs['WindowsIsoRetries'] = [int]$WindowsIsoRetries }
  if (-not [string]::IsNullOrWhiteSpace($Accelerator)) { $invokeArgs['Accelerator'] = $Accelerator }
  if ($Headful.IsPresent) { $invokeArgs['Headful'] = $true }
  elseif ($NoHeadful.IsPresent) { $invokeArgs['Headful'] = $false }
  if (-not [string]::IsNullOrWhiteSpace($VmDirOverride)) { $env:VM_DIR_OVERRIDE = $VmDirOverride }
  if ($DryRun.IsPresent) { $invokeArgs['DryRun'] = $true }
  if ($Gc.IsPresent) { $invokeArgs['Gc'] = $true }
  elseif ($NoGc.IsPresent) { $invokeArgs['Gc'] = $false }
  if ($GcDisabled.IsPresent) { $invokeArgs['GcDisabled'] = $true }
  elseif ($NoGcDisabled.IsPresent) { $invokeArgs['GcDisabled'] = $false }
  if ($Help.IsPresent) {
    Get-Help $PSCommandPath -Detailed
    exit 0
  }

  & {
    param(
      [string]$ModulePath,
      [hashtable]$InvokeArgs
    )
    . $ModulePath
    Invoke-VMSetup @InvokeArgs
  } -ModulePath $module -InvokeArgs $invokeArgs
}

function Get-VMRunningIdList {
  # Detect running VMs from QEMU processes (Windows uses QEMU).
  $module = Join-Path $RepoRoot 'src\platforms\Windows\modules\system\Invoke-VMSetup.ps1'
  if (-not (Test-Path $module)) {
    return @()
  }
  . $module
  return @(Get-VMRunningProcessNameList)
}

function Invoke-VMList {
  $manifest = Get-VMManifest
  $hostName = Get-NucleusHostKey
  $runningNameList = Get-VMRunningIdList

  # Filter to enabled VMs matching the current host
  $vms = @($manifest.VMs | Where-Object {
    $_.enabled -eq $true -and $_.hosts -contains $hostName
  })

  if ($Json.IsPresent) {
    $out = @($vms | ForEach-Object {
      $state = if ($_.id -in $runningNameList) { 'running' } else { 'stopped' }
      $props = [ordered]@{}
      foreach ($p in $_.PSObject.Properties) { $props[$p.Name] = $p.Value }
      $props['state'] = $state
      [pscustomobject]$props
    })
    # WHY -InputObject: piping a single-element array unwraps it to an object,
    # and piping an empty array produces no output.
    Write-Output (ConvertTo-Json -Compress -Depth 10 -InputObject $out)
    return
  }

  Write-Output "NAME                TYPE           ENABLED    STATE    HOSTS"
  foreach ($vm in $vms) {
    $hostsStr = ($vm.hosts -join ',')
    $state = if ($vm.id -in $runningNameList) { 'running' } else { 'stopped' }
    Write-Output ("{0,-20} {1,-14} {2,-10} {3,-9} {4}" -f $vm.name, $vm.type, $vm.enabled, $state, $hostsStr)
  }
}

function Invoke-VMStatus {
  $manifest = Get-VMManifest
  $hostName = Get-NucleusHostKey
  $runningNameList = Get-VMRunningIdList

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

function Invoke-VMStart {
  if ($SubcommandArgs.Length -eq 0) {
    Write-NucleusError 'start requires a VM name'
    exit 1
  }

  $vmName = $SubcommandArgs[0]
  Assert-NoExtraVMPositionalArg -ActionName 'start' -Consumed 1
  $vmDir = if ($env:VM_DIR_OVERRIDE) { $env:VM_DIR_OVERRIDE } else { Join-Path $env:USERPROFILE 'virtual machines' }
  $startScript = Join-Path -Path $vmDir -ChildPath 'scripts' -AdditionalChildPath "start-$vmName.ps1"

  if (Test-Path -LiteralPath $startScript -PathType Leaf) {
    Write-NucleusInfo "starting VM '$vmName' via generated script..."
    & $startScript
    return
  }

  $manifest = Get-VMManifest
  $vm = $manifest.VMs | Where-Object { $_.id -eq $vmName }
  if (-not $vm) {
    Write-NucleusError "VM '$vmName' not found in manifest"
    exit 1
  }

  Write-NucleusWarning "start script not found at $startScript; run 'nucleus-vm setup' first"
  exit 1
}

function Invoke-VMStop {
  if ($SubcommandArgs.Length -eq 0) {
    Write-NucleusError 'stop requires a VM name'
    exit 1
  }

  $vmName = $SubcommandArgs[0]
  Assert-NoExtraVMPositionalArg -ActionName 'stop' -Consumed 1
  $vmDir = if ($env:VM_DIR_OVERRIDE) { $env:VM_DIR_OVERRIDE } else { Join-Path $env:USERPROFILE 'virtual machines' }
  $stopScript = Join-Path -Path $vmDir -ChildPath 'scripts' -AdditionalChildPath "stop-$vmName.ps1"

  if (Test-Path -LiteralPath $stopScript -PathType Leaf) {
    Write-NucleusInfo "stopping VM '$vmName' via generated script..."
    & $stopScript
    return
  }

  $manifest = Get-VMManifest
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

function Invoke-VMUpgrade {
  if ($SubcommandArgs.Length -eq 0) {
    Write-NucleusError 'upgrade requires a VM name'
    exit 1
  }

  $vmName = $SubcommandArgs[0]
  Assert-NoExtraVMPositionalArg -ActionName 'upgrade' -Consumed 1
  $module = Join-Path $RepoRoot 'src\platforms\Windows\modules\system\Invoke-VMSetup.ps1'
  if (-not (Test-Path $module)) {
    Write-NucleusError "Invoke-VMSetup module not found at $module"
    exit 1
  }
  . $module

  Resolve-VMGuestCredential -RepoRoot $RepoRoot > $null
  Write-NucleusInfo "upgrading Android VM '$vmName' on Windows..."
  Write-NucleusWarning "Android upgrade on Windows is not yet fully implemented"
}

function Invoke-VMReset {
  if ($SubcommandArgs.Length -eq 0) {
    Write-NucleusError 'reset requires a VM name'
    exit 1
  }

  $vmName = $SubcommandArgs[0]
  Assert-NoExtraVMPositionalArg -ActionName 'reset' -Consumed 1
  $acceptGsiLicense = $AcceptGsiLicense.IsPresent
  if ($NoAcceptGsiLicense.IsPresent) { $acceptGsiLicense = $false }

  $manifest = Get-VMManifest
  $vm = $manifest.VMs | Where-Object { $_.id -eq $vmName }
  if (-not $vm) {
    Write-NucleusError "VM '$vmName' not found in manifest"
    exit 1
  }
  if ([string]$vm.type -ne 'Android') {
    Write-NucleusError "reset is only supported for Android VMs ('$vmName' is type $($vm.type))"
    exit 1
  }

  $setupModule = Join-Path $RepoRoot 'src\platforms\Windows\modules\system\Invoke-VMSetup.ps1'
  if (-not (Test-Path $setupModule)) {
    Write-NucleusError "Invoke-VMSetup module not found at $setupModule"
    exit 1
  }
  . $setupModule
  Resolve-VMGuestCredential -RepoRoot $RepoRoot > $null

  $androidModule = Join-Path $RepoRoot 'src\platforms\Windows\modules\system\VMAndroid.ps1'
  $configModule = Join-Path $RepoRoot 'src\platforms\Windows\modules\system\Invoke-AndroidConfig.ps1'
  if (-not (Test-Path $androidModule) -or -not (Test-Path $configModule)) {
    Write-NucleusError "Android modules not found at $androidModule or $configModule"
    exit 1
  }
  . $androidModule
  . $configModule

  $vmDir = if ($env:VM_DIR_OVERRIDE) { $env:VM_DIR_OVERRIDE } else { Join-Path $env:USERPROFILE 'virtual machines' }
  Write-NucleusInfo "resetting Android VM '$vmName' on Windows..."
  Invoke-AndroidReset -RepoRoot $RepoRoot -VmId $vmName -Manifest $manifest -VmDir $vmDir -AcceptGsiLicense:$acceptGsiLicense
}

function Invoke-VMAndroidConfig {
  if ($SubcommandArgs.Length -eq 0) {
    Write-NucleusError 'android-config requires a VM name'
    exit 1
  }

  $vmName = $SubcommandArgs[0]
  $configFlags = @()
  if ($Gapps.IsPresent) { $configFlags += '--gapps' }
  if ($AdbKeys.IsPresent) { $configFlags += '--adb-keys' }
  if ($Magisk.IsPresent) { $configFlags += '--magisk' }
  if ($Root.IsPresent) { $configFlags += '--root' }
  if ($FakeWifi.IsPresent) { $configFlags += '--fake-wifi' }
  if ($FakeWifiRevert.IsPresent) { $configFlags += '--fake-wifi-revert' }
  $extraPositional = @()
  if ($SubcommandArgs.Length -gt 1) {
    foreach ($arg in @($SubcommandArgs[1..($SubcommandArgs.Length - 1)])) {
      if ($arg -like '-*') {
        $configFlags += $arg
      } else {
        $extraPositional += $arg
      }
    }
  }
  if ($extraPositional.Count -gt 0) {
    Write-NucleusWarning "vm android-config: ignoring unexpected positional argument(s): $($extraPositional -join ', ')"
  }

  $manifest = Get-VMManifest
  $vm = $manifest.VMs | Where-Object { $_.id -eq $vmName }
  if (-not $vm) {
    Write-NucleusError "VM '$vmName' not found in manifest"
    exit 1
  }
  if ([string]$vm.type -ne 'Android') {
    Write-NucleusError "android-config is only supported for Android VMs ('$vmName' is type $($vm.type))"
    exit 1
  }

  $androidModule = Join-Path $RepoRoot 'src\platforms\Windows\modules\system\VMAndroid.ps1'
  $configModule = Join-Path $RepoRoot 'src\platforms\Windows\modules\system\Invoke-AndroidConfig.ps1'
  if (-not (Test-Path $androidModule) -or -not (Test-Path $configModule)) {
    Write-NucleusError "Android modules not found at $androidModule or $configModule"
    exit 1
  }
  . $androidModule
  . $configModule

  $vmDir = if ($env:VM_DIR_OVERRIDE) { $env:VM_DIR_OVERRIDE } else { Join-Path $env:USERPROFILE 'virtual machines' }
  Invoke-AndroidConfig -RepoRoot $RepoRoot -VmId $vmName -Manifest $manifest -VmDir $vmDir -ConfigFlags $configFlags
}

function Invoke-VMResize {
  if ($SubcommandArgs.Length -lt 2) {
    Write-NucleusError 'resize requires a VM name and a size (e.g. "nucleus-vm resize NixOS 64GB")'
    exit 1
  }

  $vmName = $SubcommandArgs[0]
  $sizeArg = $SubcommandArgs[1]
  Assert-NoExtraVMPositionalArg -ActionName 'resize' -Consumed 2
  $allowShrink = $AllowShrink.IsPresent

  $manifest = Get-VMManifest
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

  if ($vmName -in (Get-VMRunningIdList)) {
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

function Invoke-VMGc {
  $gcDisabled = $GcDisabled.IsPresent
  $gcData = $GcData.IsPresent

  $vmSh = Join-Path $RepoRoot 'scripts\vm.sh'
  if (-not (Test-Path -LiteralPath $vmSh -PathType Leaf)) {
    Write-NucleusError "vm.sh not found at $vmSh"
    exit 1
  }
  $gcArgs = @('gc')
  if ($gcDisabled) { $gcArgs += '--gc-disabled' }
  if ($gcData) { $gcArgs += '--gc-data' }
  & bash $vmSh @gcArgs
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}

function Invoke-VMPack {
  $perform = $Force.IsPresent

  if (@(Get-VMRunningIdList).Count -gt 0) {
    Write-NucleusError 'cannot pack while a VM is running; stop all VMs first'
    exit 1
  }

  $vmDir = if ($env:VM_DIR_OVERRIDE) { $env:VM_DIR_OVERRIDE } else { Join-Path $env:USERPROFILE 'virtual machines' }
  $srcDir = Join-Path $vmDir 'src'

  if (-not $perform) {
    Write-NucleusInfo 'pack (dry-run): pass --force to remove regenerable artifacts'
  }

  # Generated start/stop helper scripts (keep pack/unpack wrappers).
  $scriptsDir = Join-Path $vmDir 'scripts'
  if (Test-Path -LiteralPath $scriptsDir -PathType Container) {
    # check-suppress:suppression_doc: scripts dir may be empty or unreadable; empty enumeration is the expected path.
    Get-ChildItem -LiteralPath $scriptsDir -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^(start|stop)-.+\.(sh|ps1)$' } | ForEach-Object {
      Write-NucleusInfo "pack — removing regenerable start/stop script: $($_.FullName)"
      if ($perform) { Remove-Item -LiteralPath $_.FullName -Force }
    }
  }

  if (Test-Path -LiteralPath $srcDir -PathType Container) {
    # check-suppress:suppression_doc: src dir may hold no VM payloads; empty enumeration is the expected path.
    Get-ChildItem -LiteralPath $srcDir -Directory -ErrorAction SilentlyContinue | ForEach-Object {
      $packerDir = Join-Path $_.FullName 'Packer'
      if (Test-Path -LiteralPath $packerDir -PathType Container) {
        Write-NucleusInfo "pack — removing transient Packer directory: $packerDir"
        if ($perform) { Remove-Item -LiteralPath $packerDir -Recurse -Force }
      }
      # check-suppress:suppression_doc: transient subdirs may be absent; empty enumeration is the expected path.
      Get-ChildItem -LiteralPath $_.FullName -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like '*-build' -or $_.Name -match '^\..+' } |
        ForEach-Object {
          Write-NucleusInfo "pack — removing transient build directory: $($_.FullName)"
          if ($perform) { Remove-Item -LiteralPath $_.FullName -Recurse -Force }
        }
    }
  }

  Write-NucleusInfo 'pack — summary: stripped regenerable wrappers; payload retained (src, data, descriptors, README)'
  Write-NucleusInfo "pack — next: copy the tree to the target host, then run 'nucleus-vm unpack' or 'nucleus-vm setup' there"
  if (-not $perform) {
    Write-NucleusInfo 'pack — dry-run: nothing was removed; pass --force to perform'
  }
}

function Invoke-VMUnpack {
  $perform = -not $DryRun.IsPresent

  $vmDir = if ($env:VM_DIR_OVERRIDE) { $env:VM_DIR_OVERRIDE } else { Join-Path $env:USERPROFILE 'virtual machines' }
  $templatesDir = Join-Path $RepoRoot 'src\vms\templates'
  $scriptsDir = Join-Path $vmDir 'scripts'

  if (-not $perform) {
    Write-NucleusInfo 'unpack (dry-run): pass --force to regenerate artifacts'
  }

  # check-suppress:suppression_doc: vm dir may hold no descriptors; empty list is handled below.
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

    # Start script (PowerShell): the cross-host dispatcher for the
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
        $content = $content.Replace('__ANDROID_SYSTEM_IMAGE__', "$vmId (system).qcow2")
        $content = $content.Replace('__ANDROID_USERDATA_IMAGE__', [string]$vmDoc.Android.userdataImage)
        $content = $content.Replace('__ANDROID_GSI_IMAGE__', [string]$vmDoc.Android.gsiImage)
        $content = $content.Replace('__ANDROID_NVRAM_IMAGE__', "$vmId (nvram).fd")
        $content = $content.Replace('__HOSTFWDS__', $hostFwds)
        Write-VmUnpackFile -Path $startPs1Path -Content $content -Perform $perform
      } else {
        Write-NucleusWarning "unpack — shared Android start script not found: $androidTemplate"
      }
    } else {
      # Windows QEMU start scripts mirror Invoke-VMSetup.ps1 rendering, so the
      # cross-host templates stay single-source.
      $hostFwds = @($vmDoc.portForwards | ForEach-Object { "hostfwd=tcp::$($_.hostPort)-:$($_.guestPort)" }) -join ','
      $ramBytes = ConvertFrom-SizeString $vmDoc.ram
      # Relocatable writable-disk path: data/<id>.qcow2 relative to the VM tree
      # root (the templates cd/Push-Location before invoking QEMU).
      $diskPath = Join-Path 'data' "$vmId.qcow2"
      $qemuArch = if ($env:PROCESSOR_ARCHITECTURE -match 'ARM64|ARM') { 'aarch64' } else { 'x86_64' }
      $qemuSystem = Join-Path $env:USERPROFILE "scoop\apps\qemu\current\qemu-system-$qemuArch.exe"
      $machine = if ($qemuArch -eq 'x86_64') { 'q35' } else { 'virt' }

      $startPs1Template = Join-Path $templatesDir 'start-windows.ps1'
      if (Test-Path -LiteralPath $startPs1Template -PathType Leaf) {
        $content = (Get-Content -LiteralPath $startPs1Template -Raw)
        $content = $content.Replace('__QEMU_SYSTEM__', $qemuSystem)
        $content = $content.Replace('__VM_ID__', $vmId)
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
        $content = $content.Replace('__VM_ID__', $vmId)
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

    # Stop script (PowerShell). The .sh variant is not rendered for windows-qemu
    # hosts (stop-posix.sh dispatches to tart/utmctl/virsh only).
    $stopPs1Template = Join-Path $templatesDir 'stop-host.ps1'
    if (Test-Path -LiteralPath $stopPs1Template -PathType Leaf) {
      $content = (Get-Content -LiteralPath $stopPs1Template -Raw)
      $content = $content.Replace('__HOST_KIND__', 'windows-qemu')
      $content = $content.Replace('__VM_ID__', $vmId)
      Write-VmUnpackFile -Path $stopPs1Path -Content $content -Perform $perform
    } else {
      Write-NucleusWarning "unpack — stop-host.ps1 template not found: $stopPs1Template"
    }
  }

  # Refresh the pack/unpack wrappers (BOTH variants) for the whole tree.
  if ($perform) {
    if (-not (Test-Path -LiteralPath $scriptsDir)) { New-Item -ItemType Directory -Path $scriptsDir -Force > $null }
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
# Generated by nucleus-vm setup: pack.ps1. Delegates to nucleus-vm pack.
& nucleus-vm pack @args
exit $LASTEXITCODE
'@ -Perform $perform
  Write-VmUnpackFile -Path (Join-Path $scriptsDir 'unpack.ps1') -Content @'
# Generated by nucleus-vm setup: unpack.ps1. Delegates to nucleus-vm unpack.
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
    if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force > $null }
    Set-Content -LiteralPath $Path -Value $Content -Encoding UTF8
    Write-NucleusInfo "unpack — wrote $Path"
  } else {
    Write-NucleusInfo "unpack (dry-run): would write $Path"
  }
}

switch ($Action) {
  'setup'   { Invoke-VMSetup }
  'sync'    { Invoke-VMSync }
  'build-system' { Invoke-VMBuildSystem }
  'list'    { Invoke-VMList }
  'status'  { Invoke-VMStatus }
  'start'   { Invoke-VMStart }
  'stop'    { Invoke-VMStop }
  'upgrade' { Invoke-VMUpgrade }
  'reset'   { Invoke-VMReset }
  'android-config' { Invoke-VMAndroidConfig }
  'inject'  { Invoke-VMInject }
  'resize'  { Invoke-VMResize }
  'gc'      { Invoke-VMGc }
  'pack'    { Invoke-VMPack }
  'unpack'  { Invoke-VMUnpack }
}
