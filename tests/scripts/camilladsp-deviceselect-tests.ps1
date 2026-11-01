#Requires -Version 7.4
# Tests for src/scripts/services/camilladsp-deviceselect.ps1:
# smart playback device detection for CamillaDSP (Windows).

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$script:passCount = 0
$script:failCount = 0
$script:warnings = @()

# WHY: the resolver reports an unusable topology through the shared formatter,
# which the heartbeat imports. The stub records the message so the suite can
# assert what the daemon would log, without the formatter's command-name lookup.
function Write-NucleusWarning {
  param([string]$Message, [string]$CommandName = '')
  $script:warnings += @("$CommandName`: $Message")
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$deviceSelect = Join-Path $repoRoot 'src/scripts/services/camilladsp-deviceselect.ps1'
$heartbeat = Join-Path $repoRoot 'src/scripts/services/camilladsp-heartbeat.ps1'

# WHY: off Windows the library keeps its state under the XDG state directory, so
# a run without this wrote last-device.txt into the live daemon's directory and
# could delete the device the daemon had saved. Temp dir, one per run, matching
# what init_test_state does for the POSIX suites.
$env:XDG_STATE_HOME = Join-Path ([System.IO.Path]::GetTempPath()) ("camilladsp-tests-" + [guid]::NewGuid().ToString('N'))

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

# Build a minimal CamillaDSP config YAML with the given devices. A loopback
# capture is a Wasapi render endpoint with a null device, as the shipped Windows
# configs declare it.
function ConvertTo-ConfigYaml {
  param(
    [string]$PlaybackDevice,
    [string]$CaptureDevice = 'Loopback Audio',
    [switch]$Loopback
  )
  $playback = if ($PlaybackDevice -eq '') { 'null' } else { """$PlaybackDevice""" }
  $capture = if ($CaptureDevice -eq '') { 'null' } else { """$CaptureDevice""" }
  $backend = if ($Loopback) { 'Wasapi' } else { 'CoreAudio' }
  $loopbackLine = if ($Loopback) { "`n    loopback: true" } else { '' }
  return @"
---
devices:
  playback:
    channels: 2
    device: $playback
    type: $backend
  capture:
    channels: 2
    device: ${capture}${loopbackLine}
    type: $backend
"@
}

# Run one detection entry point in a scope where the COM-backed detection
# helpers are replaced by mocks, so no audio stack is required.
# $EntryPoint: 'resolve' (Resolve-CamillaDSPPlaybackDevice) or 'resolved'
#               (Get-CamillaDSPResolvedPlaybackDeviceName)
# $Mocks: hashtable of Default / First / Last / Available values
function Invoke-WithMockedDetection {
  param(
    [string]$ConfigYaml,
    [hashtable]$Mocks,
    [string]$EntryPoint
  )
  $script:warnings = @()
  $cfgFile = New-TemporaryFile | Rename-Item -NewName { $_ -replace '\.tmp$', '.yml' } -PassThru
  Set-Content -Path $cfgFile.FullName -Value $ConfigYaml -NoNewline
  try {
    $scriptBlock = {
      param([string]$DeviceSelectPath, [string]$ConfigPath, [hashtable]$Mocks, [string]$EntryPoint)
      . $DeviceSelectPath
      # Copy the mock values into this scope so the nested mock functions read
      # locals: a nested function scope is invisible to parameter analysis.
      $mockDefault = [string]$Mocks.Default
      $mockFirst = [string]$Mocks.First
      $mockLast = [string]$Mocks.Last
      $mockAvailable = [string[]]$Mocks.Available
      # Override COM-backed helpers with mocks so no audio stack is required.
      function Get-CamillaDSPDefaultPlaybackDevice { return $mockDefault }
      function Get-CamillaDSPAvailablePlaybackDeviceList { return $mockAvailable }
      function Get-CamillaDSPFirstAvailablePlaybackDevice { return $mockFirst }
      function Get-CamillaDSPLastDevice { return $mockLast }
      if ($EntryPoint -eq 'resolved') {
        Get-CamillaDSPResolvedPlaybackDeviceName -ConfigPath $ConfigPath
      } else {
        Resolve-CamillaDSPPlaybackDevice -ConfigPath $ConfigPath
      }
    }
    return (& $scriptBlock $deviceSelect $cfgFile.FullName $Mocks $EntryPoint)
  } finally {
    Remove-Item -Path $cfgFile.FullName -Force -ErrorAction SilentlyContinue  # check-suppress:suppression_doc: best-effort cleanup -- temp config may already be gone
  }
}

# Run Resolve-CamillaDSPPlaybackDevice with mocked detection helpers.
# $Default: value returned by Get-CamillaDSPDefaultPlaybackDevice (or $null)
# $First: value returned by Get-CamillaDSPFirstAvailablePlaybackDevice (or $null)
# $Last: value returned by Get-CamillaDSPLastDevice (or $null)
function Invoke-Resolve {
  param(
    [string]$ConfigYaml,
    [string]$Default = $null,
    [string]$First = $null,
    [string]$Last = $null,
    [string[]]$Available = @()
  )
  return Invoke-WithMockedDetection -ConfigYaml $ConfigYaml -EntryPoint 'resolve' -Mocks @{
    Default   = $Default
    First     = $First
    Last      = $Last
    Available = $Available
  }
}

# Read one function of the heartbeat without running the script: the heartbeat is
# a resident loop, so dot-sourcing it would never return. The fingerprint is pure,
# so the test defines the shipped implementation instead of copying the hash
# logic, the same seam camilladsp-wiring.Tests.ps1 uses for scripts it must not run.
function Get-HeartbeatFunctionScript {
  param([string]$Name)
  $tokens = $null
  $parseErrors = $null
  $ast = [System.Management.Automation.Language.Parser]::ParseFile($heartbeat, [ref]$tokens, [ref]$parseErrors)
  if ($parseErrors) { throw "camilladsp-heartbeat.ps1 does not parse: $($parseErrors[0].Message)" }
  $definition = $ast.Find(
    {
      $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
      $args[0].Name -eq $Name
    },
    $true
  )
  if ($null -eq $definition) { throw "camilladsp-heartbeat.ps1 has no function $Name" }
  return [scriptblock]::Create($definition.Extent.Text)
}
# Dot-sourced at script scope, because a function defined inside a helper would
# disappear with the helper's scope.
. (Get-HeartbeatFunctionScript -Name 'Get-CamillaDSPConfigFingerprint')

# Test 1: Non-null playback device → pass through unchanged.
$resolved = Invoke-Resolve -ConfigYaml (ConvertTo-ConfigYaml -PlaybackDevice 'MacBook Pro Speakers')
$device = Get-PlaybackDevice -Yaml $resolved
if ($device -eq 'MacBook Pro Speakers') {
  Assert-Pass 'non-empty playback device passes through unchanged'
} else {
  Assert-Fail 'non-empty playback device passthrough' "expected 'MacBook Pro Speakers', got '$device'"
}

# Test 2: Null playback device + default available → patched with default.
$resolved = Invoke-Resolve -ConfigYaml (ConvertTo-ConfigYaml -PlaybackDevice '') -Default 'External USB DAC'
$device = Get-PlaybackDevice -Yaml $resolved
if ($device -eq 'External USB DAC') {
  Assert-Pass 'null device patched with detected default output'
} else {
  Assert-Fail 'null device patching' "expected 'External USB DAC', got '$device'"
}

# Test 3: Default == capture → rejected, fallback used.
$resolved = Invoke-Resolve -ConfigYaml (ConvertTo-ConfigYaml -PlaybackDevice '' -CaptureDevice 'Loopback Audio') -Default 'Loopback Audio' -First 'MacBook Pro Speakers'
$device = Get-PlaybackDevice -Yaml $resolved
if ($device -eq 'MacBook Pro Speakers') {
  Assert-Pass 'capture device rejected, fallback used'
} else {
  Assert-Fail 'capture device rejection' "expected 'MacBook Pro Speakers', got '$device'"
}

# Test 4: No default + fallback available → first non-capture device selected
# deterministically (the user's scenario). Assert the exact expected device.
$resolved = Invoke-Resolve -ConfigYaml (ConvertTo-ConfigYaml -PlaybackDevice '' -CaptureDevice 'Loopback Audio') -Default '' -First 'USB Speaker'
$device = Get-PlaybackDevice -Yaml $resolved
if ($device -eq 'USB Speaker') {
  Assert-Pass 'no default → first non-capture fallback selected deterministically'
} else {
  Assert-Fail 'no-default fallback' "expected 'USB Speaker', got '$device'"
}

# Test 5: All devices are capture → null preserved.
$resolved = Invoke-Resolve -ConfigYaml (ConvertTo-ConfigYaml -PlaybackDevice '' -CaptureDevice 'Loopback Audio') -Default 'Loopback Audio' -First ''
$device = Get-PlaybackDevice -Yaml $resolved
if ($null -eq $device -or $device -eq '') {
  Assert-Pass 'null device when all available devices match capture'
} else {
  Assert-Fail 'all-capture fallback' "expected empty, got '$device'"
}

# Test 6: Non-playback fields survive YAML round-trip.
$resolved = Invoke-Resolve -ConfigYaml (ConvertTo-ConfigYaml -PlaybackDevice '') -Default 'USB Speaker'
$cfg = $resolved | ConvertFrom-Yaml
if ($cfg.devices.playback.type -eq 'CoreAudio') {
  Assert-Pass 'non-playback fields preserved after patching'
} else {
  Assert-Fail 'field preservation' "expected 'CoreAudio', got '$($cfg.devices.playback.type)'"
}

# Test 7: target device helper: returns the device detection would currently
# select (the device Resolve-CamillaDSPPlaybackDevice would set), or $null when
# detection yields nothing. This is what the heartbeat compares against so it
# re-pushes when the system default output device changes.
function Get-TargetDevice {
  param(
    [string]$ConfigYaml,
    [string]$Default = $null,
    [string]$First = $null,
    [string]$Last = $null,
    [string[]]$Available = @()
  )
  return Invoke-WithMockedDetection -ConfigYaml $ConfigYaml -EntryPoint 'resolved' -Mocks @{
    Default   = $Default
    First     = $First
    Last      = $Last
    Available = $Available
  }
}

$target = Get-TargetDevice -ConfigYaml (ConvertTo-ConfigYaml -PlaybackDevice '') -Default 'External USB DAC'
if ($target -eq 'External USB DAC') {
  Assert-Pass 'target helper returns detected default output'
} else {
  Assert-Fail 'target helper default output' "expected 'External USB DAC', got '$target'"
}

$target = Get-TargetDevice -ConfigYaml (ConvertTo-ConfigYaml -PlaybackDevice 'MacBook Pro Speakers')
if ($target -eq 'MacBook Pro Speakers') {
  Assert-Pass 'target helper returns explicit playback device'
} else {
  Assert-Fail 'target helper explicit device' "expected 'MacBook Pro Speakers', got '$target'"
}

$target = Get-TargetDevice -ConfigYaml (ConvertTo-ConfigYaml -PlaybackDevice '') -Default '' -First ''
if ([string]::IsNullOrEmpty($target)) {
  Assert-Pass 'target helper returns empty when no devices available'
} else {
  Assert-Fail 'target helper no devices' "expected empty, got '$target'"
}

# Test 8: push-decision matrix: mirrors the POSIX camilladsp_needs_push logic.
# Skip (return $true) only when Running AND (null target OR (live non-empty AND
# live == target AND the config is unchanged)). Re-push when the live device
# differs from the target (system default changed) or the config file changed.
# A null target is only skipped when Running (never push null onto a running
# instance); when not Running, an empty target still pushes so the initial config
# is set even when detection yields nothing.
function Test-ShouldSkip {
  param([string]$State, [string]$Live, [string]$Target, [bool]$ConfigChanged)
  # Replicates the heartbeat skip predicate.
  if ($State -eq 'Running' -and [string]::IsNullOrEmpty($Target)) { return $true }
  if ($State -eq 'Running' -and
      -not [string]::IsNullOrEmpty($Live) -and
      $Live -eq $Target -and
      -not $ConfigChanged) {
    return $true
  }
  return $false
}

$skipCases = @(
  @{ State = 'Running'; Live = 'MacBook Air喇叭'; Target = 'MacBook Air喇叭'; ConfigChanged = $false; Expect = $true },   # live==target + unchanged → skip
  @{ State = 'Running'; Live = 'MacBook Air喇叭'; Target = 'MacBook Air喇叭'; ConfigChanged = $true; Expect = $false },  # live==target but config edited → push
  @{ State = 'Running'; Live = 'MacBook Air喇叭'; Target = '';            ConfigChanged = $false; Expect = $true },   # null target + Running → skip (never push null)
  @{ State = 'Running'; Live = 'MacBook Air喇叭'; Target = '';            ConfigChanged = $true; Expect = $true },   # null target skips even when config changed
  @{ State = 'Running'; Live = '';            Target = 'MacBook Air喇叭'; ConfigChanged = $false; Expect = $false },  # null live → push
  @{ State = 'Running'; Live = 'Old Device';  Target = 'MacBook Air喇叭'; ConfigChanged = $false; Expect = $false },  # live != target → push (default changed)
  @{ State = 'Stopped'; Live = 'MacBook Air喇叭'; Target = 'MacBook Air喇叭'; ConfigChanged = $false; Expect = $false }, # not Running → push
  @{ State = '';       Live = 'MacBook Air喇叭'; Target = 'MacBook Air喇叭'; ConfigChanged = $false; Expect = $false }, # empty state → push
  @{ State = 'Inactive'; Live = '';            Target = '';            ConfigChanged = $false; Expect = $false },  # not Running + empty target → push (initial config)
  @{ State = 'Running'; Live = 'U18';          Target = '';            ConfigChanged = $false; Expect = $true }   # Running + null target → skip (never push null)
)
$matrixOk = $true
foreach ($c in $skipCases) {
  $got = Test-ShouldSkip -State $c.State -Live $c.Live -Target $c.Target -ConfigChanged ([bool]$c.ConfigChanged)
  if ($got -ne $c.Expect) {
    $matrixOk = $false
    Assert-Fail "should-skip($($c.State),$($c.Live),$($c.Target),$($c.ConfigChanged))" "expected $($c.Expect), got $got"
  }
}
if ($matrixOk) {
  Assert-Pass 'skip-decision re-pushes when live device differs from target'
}

# Test 9: last saved default used when no system default available.
# The saved device must appear in the available list for validation to pass.
$resolved = Invoke-Resolve -ConfigYaml (ConvertTo-ConfigYaml -PlaybackDevice '') -Default '' -First '' -Last 'Saved USB DAC' -Available @('USB Speaker', 'Saved USB DAC')
$device = Get-PlaybackDevice -Yaml $resolved
if ($device -eq 'Saved USB DAC') {
  Assert-Pass 'last saved default used when no system default available'
} else {
  Assert-Fail 'last saved default fallback' "expected 'Saved USB DAC', got '$device'"
}

# Test 10: system default wins over last saved default.
$resolved = Invoke-Resolve -ConfigYaml (ConvertTo-ConfigYaml -PlaybackDevice '') -Default 'External USB DAC' -First '' -Last 'Saved USB DAC'
$device = Get-PlaybackDevice -Yaml $resolved
if ($device -eq 'External USB DAC') {
  Assert-Pass 'system default wins over last saved default'
} else {
  Assert-Fail 'system default vs last saved' "expected 'External USB DAC', got '$device'"
}

# Test 11: last saved default rejected when it matches capture device.
$resolved = Invoke-Resolve -ConfigYaml (ConvertTo-ConfigYaml -PlaybackDevice '' -CaptureDevice 'Loopback Audio') -Default '' -First 'MacBook Pro Speakers' -Last 'Loopback Audio'
$device = Get-PlaybackDevice -Yaml $resolved
if ($device -eq 'MacBook Pro Speakers') {
  Assert-Pass 'capture-matching last saved rejected, first available used'
} else {
  Assert-Fail 'last saved capture rejection' "expected 'MacBook Pro Speakers', got '$device'"
}

# Test 12: no system default, no last saved → first available (backward compat).
$resolved = Invoke-Resolve -ConfigYaml (ConvertTo-ConfigYaml -PlaybackDevice '') -Default '' -First 'USB Speaker' -Last ''
$device = Get-PlaybackDevice -Yaml $resolved
if ($device -eq 'USB Speaker') {
  Assert-Pass 'no default + no last saved → first available (backward compat)'
} else {
  Assert-Fail 'backward compat fallback' "expected 'USB Speaker', got '$device'"
}

# Test 13: last saved matches capture AND no first available → null.
$resolved = Invoke-Resolve -ConfigYaml (ConvertTo-ConfigYaml -PlaybackDevice '' -CaptureDevice 'Loopback Audio') -Default '' -First '' -Last 'Loopback Audio' -Available @('USB Speaker')
$device = Get-PlaybackDevice -Yaml $resolved
if ($null -eq $device -or $device -eq '') {
  Assert-Pass 'last saved matches capture + no first available → null'
} else {
  Assert-Fail 'last saved capture + no fallback' "expected empty, got '$device'"
}

# Test 14: last saved device missing from available list → falls through to first available.
# When the saved device (e.g. unplugged USB DAC) no longer exists, the validation
# rejects it and falls through to first-available instead of pushing a nonexistent name.
$resolved = Invoke-Resolve -ConfigYaml (ConvertTo-ConfigYaml -PlaybackDevice '') -Default '' -First 'USB Speaker' -Last 'Old USB DAC' -Available @('USB Speaker')
$device = Get-PlaybackDevice -Yaml $resolved
if ($device -eq 'USB Speaker') {
  Assert-Pass 'last saved missing → falls through to first available'
} else {
  Assert-Fail 'last saved missing fallback' "expected 'USB Speaker', got '$device'"
}

# Test 15: a loopback capture reads a render endpoint, so the capture device is
# the default playback device and the daemon has to play to a different one.
$loopbackYaml = ConvertTo-ConfigYaml -PlaybackDevice '' -CaptureDevice '' -Loopback
$resolved = Invoke-Resolve -ConfigYaml $loopbackYaml -Default 'Speakers (Realtek)' -First 'Spare Output' -Available @('Speakers (Realtek)', 'Spare Output')
$loopbackConfig = $resolved | ConvertFrom-Yaml
if ($loopbackConfig.devices.capture.device -eq 'Speakers (Realtek)') {
  Assert-Pass 'loopback capture resolves to the default render endpoint'
} else {
  Assert-Fail 'loopback capture resolution' "expected 'Speakers (Realtek)', got '$($loopbackConfig.devices.capture.device)'"
}
if ($loopbackConfig.devices.capture.loopback -eq $true) {
  Assert-Pass 'loopback capture keeps loopback: true'
} else {
  Assert-Fail 'loopback flag preservation' "expected True, got '$($loopbackConfig.devices.capture.loopback)'"
}
$device = Get-PlaybackDevice -Yaml $resolved
if ($device -eq 'Spare Output') {
  Assert-Pass 'playback never selects the loopback capture endpoint'
} else {
  Assert-Fail 'loopback playback exclusion' "expected 'Spare Output', got '$device'"
}

# Test 16: a single render endpoint leaves no output to play to, so the config is
# pushed unpatched and the daemon reports the missing second endpoint.
$resolved = Invoke-Resolve -ConfigYaml $loopbackYaml -Default 'Speakers (Realtek)' -First '' -Last '' -Available @('Speakers (Realtek)')
if ($resolved -eq $loopbackYaml) {
  Assert-Pass 'single render endpoint leaves the config unpatched'
} else {
  Assert-Fail 'single endpoint passthrough' 'expected the config text unchanged'
}
$endpointWarnings = @($script:warnings | Where-Object { $_ -match 'second playback endpoint' })
if ($endpointWarnings.Count -eq 1) {
  Assert-Pass 'single render endpoint warns about the second playback endpoint'
} else {
  Assert-Fail 'single endpoint warning' "expected one two-endpoint warning, got $($script:warnings.Count): $($script:warnings -join ' | ')"
}

# Test 17: the fingerprint covers the resolved capture device as well, because a
# loopback capture follows the default playback device while the config bytes stay
# the same. Either endpoint changing has to look like a change.
$fingerprintFile = New-TemporaryFile | Rename-Item -NewName { $_ -replace '\.tmp$', '.yml' } -PassThru
Set-Content -Path $fingerprintFile.FullName -Value $loopbackYaml -NoNewline
try {
  $baseline = Get-CamillaDSPConfigFingerprint -ConfigPath $fingerprintFile.FullName -TargetDevice 'Spare Output' -CaptureDevice 'Speakers (Realtek)'
  $otherCapture = Get-CamillaDSPConfigFingerprint -ConfigPath $fingerprintFile.FullName -TargetDevice 'Spare Output' -CaptureDevice 'Speakers (Realtek) 2'
  $otherPlayback = Get-CamillaDSPConfigFingerprint -ConfigPath $fingerprintFile.FullName -TargetDevice 'Spare Output 2' -CaptureDevice 'Speakers (Realtek)'
  if ($baseline -ne $otherCapture) {
    Assert-Pass 'fingerprint changes with the resolved capture device'
  } else {
    Assert-Fail 'fingerprint capture separator' "both capture devices hashed to $baseline"
  }
  if ($baseline -ne $otherPlayback) {
    Assert-Pass 'fingerprint changes with the resolved playback device'
  } else {
    Assert-Fail 'fingerprint playback separator' "both playback devices hashed to $baseline"
  }
} finally {
  Remove-Item -Path $fingerprintFile.FullName -Force -ErrorAction SilentlyContinue  # check-suppress:suppression_doc: best-effort cleanup -- temp config may already be gone
}

# Test 18: a config with no playback device must never reach CamillaDSP, because
# a null playback device binds the system default output, which is the loopback
# capture endpoint here. The request stub records any push attempt.
$script:pushedPayload = $null
$script:lastPushFingerprint = $null
function Invoke-CamillaDSPRequest {
  param([int]$EndpointPort, [string]$Payload)
  $script:pushedPayload = "$EndpointPort $Payload"
  return @{ SetConfig = @{ result = 'Ok' } }
}
function Save-CamillaDSPLastPush {
  param([string]$Fingerprint)
  $script:lastPushFingerprint = $Fingerprint
}
. $deviceSelect
function Get-CamillaDSPDefaultPlaybackDevice { return 'Speakers (Realtek)' }
function Get-CamillaDSPAvailablePlaybackDeviceList { return @() }
function Get-CamillaDSPFirstAvailablePlaybackDevice { return '' }
function Get-CamillaDSPLastDevice { return '' }
. (Get-HeartbeatFunctionScript -Name 'Send-CamillaDSPConfig')

$sendConfigFile = New-TemporaryFile | Rename-Item -NewName { $_ -replace '\.tmp$', '.yml' } -PassThru
Set-Content -Path $sendConfigFile.FullName -Value $loopbackYaml -NoNewline
try {
  $pushed = Send-CamillaDSPConfig -EndpointPort 1 -ConfigPath $sendConfigFile.FullName -TargetDevice '' -CaptureDevice 'Speakers (Realtek)'
} finally {
  Remove-Item -Path $sendConfigFile.FullName -Force -ErrorAction SilentlyContinue  # check-suppress:suppression_doc: best-effort cleanup -- temp config may already be gone
}
if ($pushed -eq $false -and $null -eq $script:pushedPayload) {
  Assert-Pass 'single render endpoint never pushes a self-feeding config'
} else {
  Assert-Fail 'single endpoint push guard' "returned '$pushed' with payload '$($script:pushedPayload)'"
}

Write-Output ''
Write-Output "--- camilladsp-deviceselect tests: $script:passCount passed, $script:failCount failed ---"
Write-Output ''

exit $script:failCount
