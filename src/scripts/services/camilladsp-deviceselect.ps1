#
# Smart playback device detection for CamillaDSP (Windows).
#
# Provides Resolve-CamillaDSPPlaybackDevice which reads a config YAML file,
# detects the playback device when devices.playback.device is null using this
# priority chain:
#   1. System default output (via WASAPI COM)
#   2. Last saved default (from state file, maintained across pushes)
#   3. First available device (deterministic sorted-name fallback)
# When playback.device is already set, the config is returned unchanged.
#
# The capture device is always excluded from autodetection to prevent audio
# loops (output → capture → processed → output again).
#
# Detection helpers (Get-CamillaDSPDefaultPlaybackDevice,
# Get-CamillaDSPAvailablePlaybackDevices, Get-CamillaDSPFirstAvailablePlaybackDevice,
# Get-CamillaDSPLastDevice, Save-CamillaDSPLastDevice) are mockable for unit tests.
#
# State file: %LOCALAPPDATA%\nucleus\camilladsp\last-device.txt persists the
# last device pushed to CamillaDSP, used as fallback when no system default
# is detected.
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

function Get-CamillaDSPAvailablePlaybackDevices {
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

  # Sort by name (case-sensitive, ascending) so selection is stable across
  # reboots and Windows updates and matches the macOS/Linux case-sensitive
  # ordering, instead of relying on undocumented EnumAudioEndpoints enumeration order.
  return ($names | Sort-Object)
}

function Get-CamillaDSPFirstAvailablePlaybackDevice {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $false)]
    [string]$CaptureDevice = $null
  )

  $names = Get-CamillaDSPAvailablePlaybackDevices -CaptureDevice $CaptureDevice
  if ($null -eq $names -or $names.Count -eq 0) {
    return $null
  }
  return $names[0]
}

# --- Last saved default state file ---

$script:CamillaDSPStateDir = Join-Path $env:LOCALAPPDATA 'nucleus\camilladsp'
$script:CamillaDSPLastDeviceFile = Join-Path $script:CamillaDSPStateDir 'last-device.txt'

function Save-CamillaDSPLastDevice {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [string]$Device
  )

  if ([string]::IsNullOrEmpty($Device)) { return }
  if (-not (Test-Path $script:CamillaDSPStateDir)) {
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

  # Non-null playback device → pass through unchanged.
  if ($null -ne $playbackDevice) {
    return $yaml
  }

  # Detect system default playback device via WASAPI COM.
  $detected = Get-CamillaDSPDefaultPlaybackDevice

  # Hard invariant: if detected device matches capture device, reject it.
  # The capture device must never be used as playback — it would create
  # an audio loop (output → capture → processed → output again).
  if ($detected -eq $captureDevice) {
    $detected = $null
  }

  # Fallback 1: last saved default (maintains previously used device).
  # Validate that the saved device still exists on the system — if a USB DAC
  # was unplugged, fall through to first-available instead of pushing a
  # nonexistent device name to CamillaDSP.
  if (-not $detected) {
    $savedDevice = Get-CamillaDSPLastDevice
    if ($savedDevice -and $savedDevice -ne $captureDevice) {
      $allDevices = Get-CamillaDSPAvailablePlaybackDevices -CaptureDevice $captureDevice
      if ($null -ne $allDevices -and ($allDevices -contains $savedDevice)) {
        $detected = $savedDevice
      }
      # If enumeration failed ($null) or device missing, $detected stays null
      # and we fall through to fallback 2 (first available).
    }
  }

  # Fallback 2: first available playback device by deterministic sorted name.
  if (-not $detected) {
    $detected = Get-CamillaDSPFirstAvailablePlaybackDevice -CaptureDevice $captureDevice
  }

  # Nothing available → pass through with empty device.
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
  param(
    [Parameter(Mandatory)]
    [string]$ConfigPath
  )

  # Return the playback device name that detection would currently select for
  # the given config (the device Resolve-CamillaDSPPlaybackDevice would set), or
  # $null if detection yields nothing. Used by the heartbeat to detect when the
  # live device has drifted from the desired device (e.g. the system default
  # output device changed).
  if (-not (Test-Path $ConfigPath)) {
    return $null
  }
  $resolved = Resolve-CamillaDSPPlaybackDevice -ConfigPath $ConfigPath
  $cfg = $resolved | ConvertFrom-Yaml
  $device = $cfg.devices.playback.device
  if ($null -eq $device) { return $null }
  return [string]$device
}
