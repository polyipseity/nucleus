#
# Smart playback device detection for CamillaDSP (Windows).
#
# Provides Resolve-CamillaDSPPlaybackDevice which reads a config YAML file,
# detects the system default playback device when devices.playback.device is
# null, and returns the patched YAML.  When playback.device is already set,
# the config is returned unchanged.
#
# The capture device is always excluded from autodetection to prevent audio
# loops (output → capture → processed → output again).
#
# Dependencies: PowerShell 7+, powershell-yaml module
#
# Usage (dot-source):
#   . "$PSScriptRoot/camilladsp-deviceselect.ps1"
#   $resolved = Resolve-CamillaDSPPlaybackDevice -ConfigPath $configPath
#

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
  $detected = $null
  try {
    # 0 = eRender (playback), 0 = DMT_DEFAULT (user default)
    $enumerator = New-Object -ComObject MMDeviceEnumerator
    $endpoint = $enumerator.GetDefaultAudioEndpoint(0, 0)
    $detected = $endpoint.FriendlyName
  } catch {
    # Audio service not running or no devices.
    $null = $_  # check-suppress:suppression_doc: $_ discarded; detection failure is non-fatal
  }

  # Hard invariant: if detected device matches capture device, reject it.
  # The capture device must never be used as playback — it would create
  # an audio loop (output → capture → processed → output again).
  if ($detected -eq $captureDevice) {
    $detected = $null
  }

  # Fallback: first available playback device (not capture).
  if (-not $detected) {
    try {
      $enumerator = New-Object -ComObject MMDeviceEnumerator
      # 0 = eRender, 0x1 = DEVICE_STATE_ACTIVE
      $devices = $enumerator.EnumAudioEndpoints(0, 0x1)
      for ($i = 0; $i -lt $devices.Count; $i++) {
        $name = $devices.Item($i).FriendlyName
        if ($name -ne $captureDevice) {
          $detected = $name
          break
        }
      }
    } catch {
      # Enumeration failed.
      $null = $_  # check-suppress:suppression_doc: $_ discarded; enumeration failure is non-fatal
    }
  }

  # Nothing available → pass through with empty device.
  if (-not $detected) {
    return $yaml
  }

  # Patch YAML: set the detected device and re-serialize.
  $cfg.devices.playback.device = $detected
  $patched = $cfg | ConvertTo-Yaml
  return $patched
}
