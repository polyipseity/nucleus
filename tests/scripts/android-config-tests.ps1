#Requires -Version 7.4
# Unit tests for Windows android-config helpers (VMAndroid.ps1 / Invoke-AndroidConfig.ps1).
#
# Run with: pwsh -NoProfile -File tests/scripts/android-config-tests.ps1

[CmdletBinding()]
param()

$script:passCount = 0
$script:failCount = 0
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$vmAndroidModule = Join-Path $repoRoot 'src\hosts\Windows\modules\system\VMAndroid.ps1'
$configModule = Join-Path $repoRoot 'src\hosts\Windows\modules\system\Invoke-AndroidConfig.ps1'

function Assert-Pass {
  param([string]$Name)
  Write-Output "✓ $Name"
  $script:passCount++
}

function Assert-Fail {
  param([string]$Name, [string]$Reason)
  Write-Output "FAIL $Name : $Reason"
  $script:failCount++
}

function Test-GetAndroidVmArch {
  function Write-NucleusError { param([string]$Message) throw $Message }
  function Write-NucleusInfo { param([string]$Message) $null = $Message }
  function Write-NucleusWarning { param([string]$Message) $null = $Message }
  . $vmAndroidModule

  $androidArch = Get-AndroidVmArch -VmType 'Android'
  if ($androidArch -eq 'aarch64') {
    Assert-Pass 'Get-AndroidVmArch Android -> aarch64'
  } else {
    Assert-Fail 'Get-AndroidVmArch Android' "expected aarch64, got $androidArch"
  }

  $windowsArch = Get-AndroidVmArch -VmType 'Windows'
  if ($windowsArch -eq 'x86_64') {
    Assert-Pass 'Get-AndroidVmArch Windows -> x86_64'
  } else {
    Assert-Fail 'Get-AndroidVmArch Windows' "expected x86_64, got $windowsArch"
  }
}

function Test-GetAndroidAdbHostPort {
  function Write-NucleusError { param([string]$Message) throw $Message }
  function Write-NucleusInfo { param([string]$Message) $null = $Message }
  function Write-NucleusWarning { param([string]$Message) $null = $Message }
  . $vmAndroidModule

  $vm = [pscustomobject]@{
    id = 'Android'
    type = 'Android'
    portForwards = @(
      [pscustomobject]@{ guestPort = 5555; hostPort = 22040 }
      [pscustomobject]@{ guestPort = 5554; hostPort = 22041 }
    )
  }

  $port = Get-AndroidAdbHostPort -Vm $vm
  if ($port -eq '22040') {
    Assert-Pass 'Get-AndroidAdbHostPort uses manifest portForwards guestPort 5555'
  } else {
    Assert-Fail 'Get-AndroidAdbHostPort' "expected 22040, got $port"
  }

  $serial = Get-AndroidAdbSerial -Vm $vm
  if ($serial -eq 'localhost:22040') {
    Assert-Pass 'Get-AndroidAdbSerial localhost:hostPort'
  } else {
    Assert-Fail 'Get-AndroidAdbSerial' "expected localhost:22040, got $serial"
  }
}

function Test-ResolveAndroidVmIndex {
  function Write-NucleusError { param([string]$Message) throw $Message }
  function Write-NucleusInfo { param([string]$Message) $null = $Message }
  function Format-NucleusOutput { param([string]$Message) $Message }
  . $configModule

  $manifest = [pscustomobject]@{
    VMs = @(
      [pscustomobject]@{ id = 'NixOS'; type = 'NixOS' }
      [pscustomobject]@{ id = 'Android'; type = 'Android' }
    )
  }

  $index = Resolve-AndroidVmIndex -Manifest $manifest -VmId 'Android'
  if ($index -eq 1) {
    Assert-Pass 'Resolve-AndroidVmIndex finds Android VM'
  } else {
    Assert-Fail 'Resolve-AndroidVmIndex' "expected 1, got $index"
  }

  $missing = Resolve-AndroidVmIndex -Manifest $manifest -VmId 'Missing'
  if ($missing -eq -1) {
    Assert-Pass 'Resolve-AndroidVmIndex returns -1 for missing VM'
  } else {
    Assert-Fail 'Resolve-AndroidVmIndex missing' "expected -1, got $missing"
  }
}

function Test-NoFlagsShowsManual {
  function Write-NucleusError { param([string]$Message) throw $Message }
  function Write-NucleusInfo { param([string]$Message) $null = $Message }
  function Format-NucleusOutput { param([string]$Message) $Message }
  . $configModule
  function Show-AndroidConfigManual { $script:manualShown = $true }

  $manifest = [pscustomobject]@{
    VMs = @([pscustomobject]@{ id = 'Android'; type = 'Android' })
  }

  $script:manualShown = $false
  Invoke-AndroidConfig -RepoRoot $repoRoot -VmId 'Android' -Manifest $manifest -VmDir 'C:\tmp' -ConfigFlags @()
  if ($script:manualShown) {
    Assert-Pass 'Invoke-AndroidConfig with no flags shows manual'
  } else {
    Assert-Fail 'Invoke-AndroidConfig no flags' 'Show-AndroidConfigManual was not called'
  }
}

function Test-UnknownFlagRejected {
  function Write-NucleusError { param([string]$Message) $script:errored = $true; throw $Message }
  function Write-NucleusInfo { param([string]$Message) $null = $Message }
  function Format-NucleusOutput { param([string]$Message) $Message }
  . $configModule

  $manifest = [pscustomobject]@{
    VMs = @([pscustomobject]@{ id = 'Android'; type = 'Android' })
  }

  $script:errored = $false
  try {
    Invoke-AndroidConfig -RepoRoot $repoRoot -VmId 'Android' -Manifest $manifest -VmDir 'C:\tmp' -ConfigFlags @('--adb-debug')
  } catch {
    $null = $_
  }

  if ($script:errored) {
    Assert-Pass 'Invoke-AndroidConfig rejects --adb-debug typo'
  } else {
    Assert-Fail 'Invoke-AndroidConfig --adb-debug' 'expected Write-NucleusError'
  }
}

Test-GetAndroidVmArch
Test-GetAndroidAdbHostPort
Test-ResolveAndroidVmIndex
Test-NoFlagsShowsManual
Test-UnknownFlagRejected

if ($script:failCount -gt 0) {
  Write-Output "android-config-tests.ps1: $($script:failCount) failure(s)"
  exit 1
}

Write-Output "android-config-tests.ps1: all passed ($($script:passCount) tests)"
exit 0
