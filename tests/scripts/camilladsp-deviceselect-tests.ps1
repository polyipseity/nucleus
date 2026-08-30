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
# $Last     — value returned by Get-CamillaDSPLastDevice (or $null)
function Invoke-Resolve {
  param(
    [string]$ConfigYaml,
    [string]$Default = $null,
    [string]$First = $null,
    [string]$Last = $null
  )
  $cfgFile = New-TemporaryFile | Rename-Item -NewName { $_ -replace '\.tmp$', '.yml' } -PassThru
  Set-Content -Path $cfgFile.FullName -Value $ConfigYaml -NoNewline
  try {
    $scriptBlock = {
      param([string]$DeviceSelectPath, [string]$ConfigPath, [string]$MockDefault, [string]$MockFirst, [string]$MockLast)
      . $DeviceSelectPath
      # Override COM-backed helpers with mocks so no audio stack is required.
      function Get-CamillaDSPDefaultPlaybackDevice { return $MockDefault }
      function Get-CamillaDSPFirstAvailablePlaybackDevice { return $MockFirst }
      function Get-CamillaDSPLastDevice { return $MockLast }
      Resolve-CamillaDSPPlaybackDevice -ConfigPath $ConfigPath
    }
    return (& $scriptBlock $deviceSelect $cfgFile.FullName $Default $First $Last)
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

# Test 7: target device helper — returns the device detection would currently
# select (the device Resolve-CamillaDSPPlaybackDevice would set), or $null when
# detection yields nothing. This is what the heartbeat compares against so it
# re-pushes when the system default output device changes.
function Get-TargetDevice {
  param([string]$ConfigYaml, [string]$Default = $null, [string]$First = $null, [string]$Last = $null)
  $cfgFile = New-TemporaryFile | Rename-Item -NewName { $_ -replace '\.tmp$', '.yml' } -PassThru
  Set-Content -Path $cfgFile.FullName -Value $ConfigYaml -NoNewline
  try {
    $scriptBlock = {
      param([string]$DeviceSelectPath, [string]$ConfigPath, [string]$MockDefault, [string]$MockFirst, [string]$MockLast)
      . $DeviceSelectPath
      function Get-CamillaDSPDefaultPlaybackDevice { return $MockDefault }
      function Get-CamillaDSPFirstAvailablePlaybackDevice { return $MockFirst }
      function Get-CamillaDSPLastDevice { return $MockLast }
      Get-CamillaDSPResolvedPlaybackDeviceName -ConfigPath $ConfigPath
    }
    return (& $scriptBlock $deviceSelect $cfgFile.FullName $Default $First $Last)
  } finally {
    Remove-Item -Path $cfgFile.FullName -Force -ErrorAction SilentlyContinue  # check-suppress:suppression_doc: best-effort cleanup -- temp config may already be gone
  }
}

$target = Get-TargetDevice -ConfigYaml (New-Config -PlaybackDevice '') -Default 'External USB DAC'
if ($target -eq 'External USB DAC') {
  Assert-Pass 'target helper returns detected default output'
} else {
  Assert-Fail 'target helper default output' "expected 'External USB DAC', got '$target'"
}

$target = Get-TargetDevice -ConfigYaml (New-Config -PlaybackDevice 'MacBook Pro Speakers')
if ($target -eq 'MacBook Pro Speakers') {
  Assert-Pass 'target helper returns explicit playback device'
} else {
  Assert-Fail 'target helper explicit device' "expected 'MacBook Pro Speakers', got '$target'"
}

$target = Get-TargetDevice -ConfigYaml (New-Config -PlaybackDevice '') -Default '' -First ''
if ([string]::IsNullOrEmpty($target)) {
  Assert-Pass 'target helper returns empty when no devices available'
} else {
  Assert-Fail 'target helper no devices' "expected empty, got '$target'"
}

# Test 8: push-decision matrix — mirrors the POSIX camilladsp_needs_push logic.
# Skip (return $true) only when Running AND (null target OR (live non-empty AND
# live == target)). Re-push when the live device differs from the target (system
# default changed). A null target is only skipped when Running (never push null
# onto a running instance); when not Running, an empty target still pushes so the
# initial config is set even when detection yields nothing.
function Test-ShouldSkip {
  param([string]$State, [string]$Live, [string]$Target)
  # Replicates the heartbeat skip predicate.
  if ($State -eq 'Running' -and [string]::IsNullOrEmpty($Target)) { return $true }
  if ($State -eq 'Running' -and
      -not [string]::IsNullOrEmpty($Live) -and
      $Live -eq $Target) {
    return $true
  }
  return $false
}

$skipCases = @(
  @{ State = 'Running'; Live = 'MacBook Air喇叭'; Target = 'MacBook Air喇叭'; Expect = $true },   # live==target → skip
  @{ State = 'Running'; Live = 'MacBook Air喇叭'; Target = '';            Expect = $true },   # null target + Running → skip (never push null)
  @{ State = 'Running'; Live = '';            Target = 'MacBook Air喇叭'; Expect = $false },  # null live → push
  @{ State = 'Running'; Live = 'Old Device';  Target = 'MacBook Air喇叭'; Expect = $false },  # live != target → push (default changed)
  @{ State = 'Stopped'; Live = 'MacBook Air喇叭'; Target = 'MacBook Air喇叭'; Expect = $false }, # not Running → push
  @{ State = '';       Live = 'MacBook Air喇叭'; Target = 'MacBook Air喇叭'; Expect = $false }, # empty state → push
  @{ State = 'Inactive'; Live = '';            Target = '';            Expect = $false },  # not Running + empty target → push (initial config)
  @{ State = 'Running'; Live = 'U18';          Target = '';            Expect = $true }   # Running + null target → skip (never push null)
)
$matrixOk = $true
foreach ($c in $skipCases) {
  $got = Test-ShouldSkip -State $c.State -Live $c.Live -Target $c.Target
  if ($got -ne $c.Expect) {
    $matrixOk = $false
    Assert-Fail "should-skip($($c.State),$($c.Live),$($c.Target))" "expected $($c.Expect), got $got"
  }
}
if ($matrixOk) {
  Assert-Pass 'skip-decision re-pushes when live device differs from target'
}

# Test 9: last saved default used when no system default available.
$resolved = Invoke-Resolve -ConfigYaml (New-Config -PlaybackDevice '') -Default '' -First '' -Last 'Saved USB DAC'
$device = Get-PlaybackDevice -Yaml $resolved
if ($device -eq 'Saved USB DAC') {
  Assert-Pass 'last saved default used when no system default available'
} else {
  Assert-Fail 'last saved default fallback' "expected 'Saved USB DAC', got '$device'"
}

# Test 10: system default wins over last saved default.
$resolved = Invoke-Resolve -ConfigYaml (New-Config -PlaybackDevice '') -Default 'External USB DAC' -First '' -Last 'Saved USB DAC'
$device = Get-PlaybackDevice -Yaml $resolved
if ($device -eq 'External USB DAC') {
  Assert-Pass 'system default wins over last saved default'
} else {
  Assert-Fail 'system default vs last saved' "expected 'External USB DAC', got '$device'"
}

# Test 11: last saved default rejected when it matches capture device.
$resolved = Invoke-Resolve -ConfigYaml (New-Config -PlaybackDevice '' -CaptureDevice 'Loopback Audio') -Default '' -First 'MacBook Pro Speakers' -Last 'Loopback Audio'
$device = Get-PlaybackDevice -Yaml $resolved
if ($device -eq 'MacBook Pro Speakers') {
  Assert-Pass 'capture-matching last saved rejected, first available used'
} else {
  Assert-Fail 'last saved capture rejection' "expected 'MacBook Pro Speakers', got '$device'"
}

# Test 12: no system default, no last saved → first available (backward compat).
$resolved = Invoke-Resolve -ConfigYaml (New-Config -PlaybackDevice '') -Default '' -First 'USB Speaker' -Last ''
$device = Get-PlaybackDevice -Yaml $resolved
if ($device -eq 'USB Speaker') {
  Assert-Pass 'no default + no last saved → first available (backward compat)'
} else {
  Assert-Fail 'backward compat fallback' "expected 'USB Speaker', got '$device'"
}

# Test 13: last saved matches capture AND no first available → null.
$resolved = Invoke-Resolve -ConfigYaml (New-Config -PlaybackDevice '' -CaptureDevice 'Loopback Audio') -Default '' -First '' -Last 'Loopback Audio'
$device = Get-PlaybackDevice -Yaml $resolved
if ($null -eq $device -or $device -eq '') {
  Assert-Pass 'last saved matches capture + no first available → null'
} else {
  Assert-Fail 'last saved capture + no fallback' "expected empty, got '$device'"
}

Write-Output ''
Write-Output "--- camilladsp-deviceselect tests: $script:passCount passed, $script:failCount failed ---"
Write-Output ''

exit $script:failCount
