#Requires -Version 7.4
# Tests for src/scripts/services/camilladsp-deviceselect.ps1 —
# smart playback device detection for CamillaDSP (Windows).

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$script:passCount = 0
$script:failCount = 0

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$deviceSelect = Join-Path $repoRoot 'src/scripts/services/camilladsp-deviceselect.ps1'

function Assert-Pass {
  param([string]$Name)
  Write-Output "PASS $Name"
  $script:passCount++
}

function Assert-Fail {
  param([string]$Name, [string]$Reason)
  Write-Output "FAIL $Name : $Reason"
  $script:failCount++
}

# Extract the resolved playback.device from a YAML string.
function Get-PlaybackDevice {
  param([string]$Yaml)
  $cfg = $Yaml | ConvertFrom-Yaml
  return $cfg.devices.playback.device
}

# Build a minimal CamillaDSP config YAML with the given devices.
function New-Config {
  param(
    [string]$PlaybackDevice,
    [string]$CaptureDevice = 'Loopback Audio'
  )
  $device = if ($PlaybackDevice -eq '') { 'null' } else { """$PlaybackDevice""" }
  return @"
---
devices:
  playback:
    channels: 2
    device: $device
    type: CoreAudio
  capture:
    channels: 2
    device: "$CaptureDevice"
    type: CoreAudio
"@
}

# Run Resolve-CamillaDSPPlaybackDevice with mocked detection helpers.
# $Default  — value returned by Get-CamillaDSPDefaultPlaybackDevice (or $null)
# $First    — value returned by Get-CamillaDSPFirstAvailablePlaybackDevice (or $null)
function Invoke-Resolve {
  param(
    [string]$ConfigYaml,
    [string]$Default = $null,
    [string]$First = $null
  )
  $cfgFile = New-TemporaryFile | Rename-Item -NewName { $_ -replace '\.tmp$', '.yml' } -PassThru
  Set-Content -Path $cfgFile.FullName -Value $ConfigYaml -NoNewline
  try {
    $scriptBlock = {
      param([string]$DeviceSelectPath, [string]$ConfigPath, [string]$MockDefault, [string]$MockFirst)
      . $DeviceSelectPath
      # Override COM-backed helpers with mocks so no audio stack is required.
      function Get-CamillaDSPDefaultPlaybackDevice { return $MockDefault }
      function Get-CamillaDSPFirstAvailablePlaybackDevice { return $MockFirst }
      Resolve-CamillaDSPPlaybackDevice -ConfigPath $ConfigPath
    }
    return (& $scriptBlock $deviceSelect $cfgFile.FullName $Default $First)
  } finally {
    Remove-Item -Path $cfgFile.FullName -Force -ErrorAction SilentlyContinue  # check-suppress:suppression_doc: best-effort cleanup -- temp config may already be gone
  }
}

# Test 1: Non-null playback device → pass through unchanged.
$resolved = Invoke-Resolve -ConfigYaml (New-Config -PlaybackDevice 'MacBook Pro Speakers')
$device = Get-PlaybackDevice -Yaml $resolved
if ($device -eq 'MacBook Pro Speakers') {
  Assert-Pass 'non-empty playback device passes through unchanged'
} else {
  Assert-Fail 'non-empty playback device passthrough' "expected 'MacBook Pro Speakers', got '$device'"
}

# Test 2: Null playback device + default available → patched with default.
$resolved = Invoke-Resolve -ConfigYaml (New-Config -PlaybackDevice '') -Default 'External USB DAC'
$device = Get-PlaybackDevice -Yaml $resolved
if ($device -eq 'External USB DAC') {
  Assert-Pass 'null device patched with detected default output'
} else {
  Assert-Fail 'null device patching' "expected 'External USB DAC', got '$device'"
}

# Test 3: Default == capture → rejected, fallback used.
$resolved = Invoke-Resolve -ConfigYaml (New-Config -PlaybackDevice '' -CaptureDevice 'Loopback Audio') -Default 'Loopback Audio' -First 'MacBook Pro Speakers'
$device = Get-PlaybackDevice -Yaml $resolved
if ($device -eq 'MacBook Pro Speakers') {
  Assert-Pass 'capture device rejected, fallback used'
} else {
  Assert-Fail 'capture device rejection' "expected 'MacBook Pro Speakers', got '$device'"
}

# Test 4: No default + fallback available → first non-capture device selected
# deterministically (the user's scenario). Assert the exact expected device.
$resolved = Invoke-Resolve -ConfigYaml (New-Config -PlaybackDevice '' -CaptureDevice 'Loopback Audio') -Default '' -First 'USB Speaker'
$device = Get-PlaybackDevice -Yaml $resolved
if ($device -eq 'USB Speaker') {
  Assert-Pass 'no default → first non-capture fallback selected deterministically'
} else {
  Assert-Fail 'no-default fallback' "expected 'USB Speaker', got '$device'"
}

# Test 5: All devices are capture → null preserved.
$resolved = Invoke-Resolve -ConfigYaml (New-Config -PlaybackDevice '' -CaptureDevice 'Loopback Audio') -Default 'Loopback Audio' -First ''
$device = Get-PlaybackDevice -Yaml $resolved
if ($null -eq $device -or $device -eq '') {
  Assert-Pass 'null device when all available devices match capture'
} else {
  Assert-Fail 'all-capture fallback' "expected empty, got '$device'"
}

# Test 6: Non-playback fields survive YAML round-trip.
$resolved = Invoke-Resolve -ConfigYaml (New-Config -PlaybackDevice '') -Default 'USB Speaker'
$cfg = $resolved | ConvertFrom-Yaml
if ($cfg.devices.playback.type -eq 'CoreAudio') {
  Assert-Pass 'non-playback fields preserved after patching'
} else {
  Assert-Fail 'field preservation' "expected 'CoreAudio', got '$($cfg.devices.playback.type)'"
}

Write-Output ''
Write-Output "--- camilladsp-deviceselect tests: $script:passCount passed, $script:failCount failed ---"
Write-Output ''

exit $script:failCount
