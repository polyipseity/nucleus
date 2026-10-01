#
# Smart playback device detection for CamillaDSP (Windows).
#
# Resolve-CamillaDSPPlaybackDevice reads a config YAML file and, when
# devices.playback.device is null, detects one in this order: system default output
# (WASAPI COM), last saved default (state file), first available device (sorted-name
# fallback). A config that already sets playback.device is returned unchanged.
#
# The capture device is always excluded, to prevent an audio loop
# (output -> capture -> processed -> output again).
#
# State file: %LOCALAPPDATA%\nucleus\camilladsp\last-device.txt holds the last device
# pushed to CamillaDSP, used as fallback when no system default is detected.
#
# Dependencies: PowerShell 7+, powershell-yaml module
#
# Usage (dot-source):
#   . "$PSScriptRoot/camilladsp-deviceselect.ps1"
#   $resolved = Resolve-CamillaDSPPlaybackDevice -ConfigPath $configPath
#

function Get-CamillaDSPDefaultPlaybackDevice {
  [CmdletBinding()]
  param()

  # Detect system default playback device via WASAPI COM.
  try {
    # 0 = eRender (playback), 0 = DMT_DEFAULT (user default)
    $enumerator = New-Object -ComObject MMDeviceEnumerator
    $endpoint = $enumerator.GetDefaultAudioEndpoint(0, 0)
    return $endpoint.FriendlyName
  } catch {
    # Audio service not running or no devices.
    $null = $_  # check-suppress:suppression_doc: $_ discarded; detection failure is non-fatal
    return $null
  }
}

function Get-CamillaDSPAvailablePlaybackDeviceList {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $false)]
    [string]$CaptureDevice = $null
  )

  # Enumerate active render endpoints and collect names, excluding capture.
  try {
    $enumerator = New-Object -ComObject MMDeviceEnumerator
    # 0 = eRender, 0x1 = DEVICE_STATE_ACTIVE
    $devices = $enumerator.EnumAudioEndpoints(0, 0x1)
    $names = @()
    for ($i = 0; $i -lt $devices.Count; $i++) {
      $name = $devices.Item($i).FriendlyName
      if ($name -ne $CaptureDevice) {
        $names += $name
      }
    }
  } catch {
    # Enumeration failed.
    $null = $_  # check-suppress:suppression_doc: $_ discarded; enumeration failure is non-fatal
    return $null
  }

  # Sort by name (case-sensitive, ascending) so selection stays stable across reboots
  # and Windows updates and matches the macOS/Linux ordering, instead of relying on
  # undocumented EnumAudioEndpoints enumeration order.
  return ($names | Sort-Object)
}

function Get-CamillaDSPFirstAvailablePlaybackDevice {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $false)]
    [string]$CaptureDevice = $null
  )

  $names = Get-CamillaDSPAvailablePlaybackDeviceList -CaptureDevice $CaptureDevice
  if ($null -eq $names -or $names.Count -eq 0) {
    return $null
  }
  return $names[0]
}

# --- Last saved default state file ---

# WHY: $env:LOCALAPPDATA is null off Windows, so resolving the state dir
# unconditionally made this library impossible to source on macOS/Linux and
# blocked its test suite there. Mirrors the POSIX library's XDG state location on
# those platforms; Windows is unchanged.
$script:CamillaDSPStateDir = if ($IsWindows) {
  Join-Path $env:LOCALAPPDATA 'nucleus\camilladsp'
} else {
  Join-Path $HOME '.local/state/camilladsp'
}
$script:CamillaDSPLastDeviceFile = Join-Path $script:CamillaDSPStateDir 'last-device.txt'

function Save-CamillaDSPLastDevice {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [string]$Device
  )

  if ([string]::IsNullOrEmpty($Device)) { return }
  if (-not (Test-Path $script:CamillaDSPStateDir)) {
    # check-suppress:suppression_doc: return value discarded; directory creation is side-effect only
    $null = New-Item -ItemType Directory -Path $script:CamillaDSPStateDir -Force
  }
  Set-Content -Path $script:CamillaDSPLastDeviceFile -Value $Device -NoNewline
}

function Get-CamillaDSPLastDevice {
  [CmdletBinding()]
  param()

  if (Test-Path $script:CamillaDSPLastDeviceFile) {
    $content = Get-Content -Raw $script:CamillaDSPLastDeviceFile
    if (-not [string]::IsNullOrWhiteSpace($content)) {
      return $content.Trim()
    }
  }
  return $null
}

function Resolve-CamillaDSPPlaybackDevice {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [string]$ConfigPath
  )

  $yaml = Get-Content -Raw $ConfigPath
  $cfg = $yaml | ConvertFrom-Yaml

  $playbackDevice = $cfg.devices.playback.device
  $captureDevice = $cfg.devices.capture.device

  # Non-null playback device passes through unchanged.
  if ($null -ne $playbackDevice) {
    return $yaml
  }

  # Detect system default playback device via WASAPI COM.
  $detected = Get-CamillaDSPDefaultPlaybackDevice

  # Hard invariant: the capture device must never be used as playback, which would
  # create an audio loop (output -> capture -> processed -> output again).
  if ($detected -eq $captureDevice) {
    $detected = $null
  }

  # Fallback 1: last saved default. Rejected when the device is gone from the
  # system, since pushing a nonexistent name would fail; the run falls through to
  # first-available instead.
  if (-not $detected) {
    $savedDevice = Get-CamillaDSPLastDevice
    if ($savedDevice -and $savedDevice -ne $captureDevice) {
      $allDevices = Get-CamillaDSPAvailablePlaybackDeviceList -CaptureDevice $captureDevice
      if ($null -ne $allDevices -and ($allDevices -contains $savedDevice)) {
        $detected = $savedDevice
      }
      # Enumeration failure ($null) or a missing device leaves $detected null, so
      # this falls through to fallback 2.
    }
  }

  # Fallback 2: first available playback device by deterministic sorted name.
  if (-not $detected) {
    $detected = Get-CamillaDSPFirstAvailablePlaybackDevice -CaptureDevice $captureDevice
  }

  # Nothing available: pass through with an empty device.
  if (-not $detected) {
    return $yaml
  }

  # Patch YAML: set the detected device and re-serialize.
  $cfg.devices.playback.device = $detected
  $patched = $cfg | ConvertTo-Yaml

  # Save the resolved device to state file for future fallback.
  Save-CamillaDSPLastDevice -Device $detected

  return $patched
}

function Get-CamillaDSPResolvedPlaybackDeviceName {
  [CmdletBinding()]
  [OutputType([string])]
  param(
    [Parameter(Mandatory)]
    [string]$ConfigPath
  )

  # The device the heartbeat compares the live device against, or $null when
  # detection yields nothing, so it can detect a drift away from the desired device.
  if (-not (Test-Path $ConfigPath)) {
    return $null
  }
  $resolved = Resolve-CamillaDSPPlaybackDevice -ConfigPath $ConfigPath
  $cfg = $resolved | ConvertFrom-Yaml
  $device = $cfg.devices.playback.device
  if ($null -eq $device) { return $null }
  return [string]$device
}
