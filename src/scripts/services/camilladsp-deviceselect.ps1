#
# Playback device detection, config resolution, and device cache for
# CamillaDSP on Windows.
#
# Resolve-CamillaDSPPlaybackDevice reads a config YAML file and, when
# devices.playback.device is null, detects one in this order: system default
# output (WASAPI COM), last saved default validated against the available
# devices, first available device in sorted-name order. A config that already
# sets playback.device is returned unchanged.
#
# A loopback capture reads a render endpoint: with devices.capture.loopback set
# and no capture device, the capture side is the default playback endpoint, so
# that endpoint is resolved for the capture and never selected for playback.
# Source: camilladsp v4.1.3 src/wasapi_backend/device.rs (find_device switches to
# the Render direction in loopback mode) and backend_wasapi.md.
#
# When no playback candidate remains, the config is returned unchanged and one
# warning names the cause: a failed endpoint enumeration, or the second endpoint
# the loopback topology needs. The warning repeats only when the cause changes,
# because a broken topology would otherwise log on every tick.
#
# State files live in Get-CamillaDSPStateDir:
#   last-device.txt          last device pushed to CamillaDSP
#   available-devices.txt    enumerated device names, one per line
#   available-devices.meta   capture device, then the enumeration epoch
#
# Dependencies: PowerShell 7+, the powershell-yaml module, and Write-NucleusWarning
# from Format-NucleusOutput.psm1. That function is resolved in the caller's scope,
# because the heartbeat imports the formatter for its own messages; a caller that
# dot-sources this library without it has to stub it (the suite does).
#
# Usage (dot-source):
#   . "$PSScriptRoot/camilladsp-deviceselect.ps1"
#   $resolved = Resolve-CamillaDSPPlaybackDevice -ConfigPath $configPath
#

function Get-CamillaDSPStateDir {
  <#
  .SYNOPSIS
    Directory holding the CamillaDSP state files.
  .DESCRIPTION
    Windows keeps state under %LOCALAPPDATA%\nucleus\camilladsp. Off Windows
    the directory follows the XDG state location, so a test run can point
    XDG_STATE_HOME at a temporary directory instead of a live daemon's state.
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param()

  if ($IsWindows) {
    return (Join-Path -Path $env:LOCALAPPDATA -ChildPath 'nucleus\camilladsp')
  }
  if (-not [string]::IsNullOrEmpty($env:XDG_STATE_HOME)) {
    return (Join-Path -Path $env:XDG_STATE_HOME -ChildPath 'camilladsp')
  }
  return (Join-Path -Path $HOME -ChildPath '.local/state/camilladsp')
}

function Get-CamillaDSPDefaultPlaybackDevice {
  <#
  .SYNOPSIS
    Name of the current system default playback device, or $null.
  .DESCRIPTION
    Reads the WASAPI default render endpoint through COM, which exists only on
    Windows. Off Windows the probe returns $null so this library and its suite
    can be sourced on macOS and Linux.
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param()

  if (-not $IsWindows) { return $null }

  try {
    # 0 = eRender (playback), 0 = DMT_DEFAULT (user default)
    $enumerator = New-Object -ComObject MMDeviceEnumerator
    $endpoint = $enumerator.GetDefaultAudioEndpoint(0, 0)
    return $endpoint.FriendlyName
  } catch {
    # Audio service not running or no devices.
    return $null
  }
}

function Get-CamillaDSPAvailablePlaybackDeviceList {
  <#
  .SYNOPSIS
    Active render endpoints, capture device excluded and sorted by name.
  .DESCRIPTION
    Returns $null when enumeration fails, so a caller can tell a failed read
    from an empty list. Names are sorted with Sort-Object, so selection is
    deterministic on a given machine instead of following the undocumented
    EnumAudioEndpoints order.
  .PARAMETER CaptureDevice
    Device to exclude; playback and capture on one device is an audio loop.
  #>
  [CmdletBinding()]
  [OutputType([string[]])]
  param(
    [Parameter(Mandatory = $false)]
    [string]$CaptureDevice = ''
  )

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
    return $null
  }

  # WHY: a bare return unrolls the array, so an empty successful enumeration
  # would reach the caller as no output and read as a failed enumeration.
  Write-Output -InputObject ([string[]]@($names | Sort-Object)) -NoEnumerate
}

function Get-CamillaDSPDeviceCacheTtl {
  <#
  .SYNOPSIS
    Device cache lifetime in seconds.
  .DESCRIPTION
    CAMILLADSP_DEVICE_CACHE_TTL overrides the 300 second default. A value that
    is not an integer leaves the default in place, as the Python daemon does.
  #>
  [CmdletBinding()]
  [OutputType([int])]
  param()

  $parsed = 0
  if ([int]::TryParse($env:CAMILLADSP_DEVICE_CACHE_TTL, [ref]$parsed)) {
    return $parsed
  }
  return 300
}

function Get-CamillaDSPAvailablePlaybackDeviceCache {
  <#
  .SYNOPSIS
    Enumerated playback devices, reusing the cache while it can still answer.
  .DESCRIPTION
    The cache is reusable only when the capture device matches, the age is
    inside the TTL, and, when a required device is given, that device is in the
    cached list. The raw probe name is deliberately not part of the key,
    because it flips between ticks and every flip would cost a full
    enumeration. Returns $null when enumeration fails.
  .PARAMETER CaptureDevice
    Device excluded from playback selection; part of the cache key.
  .PARAMETER RequiredDevice
    Device the caller needs listed, otherwise the cache is bypassed.
  #>
  [CmdletBinding()]
  [OutputType([string[]])]
  param(
    [Parameter(Mandatory = $false)]
    [string]$CaptureDevice = '',

    [Parameter(Mandatory = $false)]
    [string]$RequiredDevice = ''
  )

  $stateDir = Get-CamillaDSPStateDir
  $cacheFile = Join-Path -Path $stateDir -ChildPath 'available-devices.txt'
  $metaFile = Join-Path -Path $stateDir -ChildPath 'available-devices.meta'
  $ttl = Get-CamillaDSPDeviceCacheTtl

  if ((Test-Path -Path $cacheFile -PathType Leaf) -and (Test-Path -Path $metaFile -PathType Leaf)) {
    $meta = @(Get-Content -Path $metaFile)
    if ($meta.Count -ge 2) {
      $cachedAt = [long]0
      $age = [long]-1
      if ([long]::TryParse($meta[1], [ref]$cachedAt)) {
        $age = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - $cachedAt
      }
      $cached = @(Get-Content -Path $cacheFile | Where-Object { -not [string]::IsNullOrEmpty($_) })
      $reusable = $meta[0] -eq $CaptureDevice
      # A non-negative age is required so TTL=0 means "never reuse" instead of
      # letting a clock skew pin a stale list indefinitely.
      if ($age -lt 0 -or $age -ge $ttl) { $reusable = $false }
      if (-not [string]::IsNullOrEmpty($RequiredDevice) -and $cached -notcontains $RequiredDevice) {
        $reusable = $false
      }
      if ($reusable) { Write-Output -InputObject ([string[]]$cached) -NoEnumerate; return }
    }
  }

  $devices = Get-CamillaDSPAvailablePlaybackDeviceList -CaptureDevice $CaptureDevice
  if ($null -eq $devices) { return $null }

  New-Item -ItemType Directory -Path $stateDir -Force > $null
  Set-Content -Path $metaFile -Value @($CaptureDevice, [DateTimeOffset]::UtcNow.ToUnixTimeSeconds())
  Set-Content -Path $cacheFile -Value $devices
  # WHY: an empty list has to stay an empty array here too, or the caller reads
  # it as a failed enumeration.
  Write-Output -InputObject ([string[]]$devices) -NoEnumerate
}

function Clear-CamillaDSPDeviceCache {
  <#
  .SYNOPSIS
    Drops the device enumeration cache.
  .DESCRIPTION
    Called when CamillaDSP rejects a pushed config: the resolved device is
    probably gone even though the cache still lists it. Not called on transport
    failures, because an unreachable websocket must not force a full
    enumeration on every tick.
  #>
  [CmdletBinding()]
  param()

  $stateDir = Get-CamillaDSPStateDir
  foreach ($name in @('available-devices.txt', 'available-devices.meta')) {
    $path = Join-Path -Path $stateDir -ChildPath $name
    if (Test-Path -Path $path -PathType Leaf) {
      Remove-Item -Path $path -Force
    }
  }
}

function Get-CamillaDSPFirstAvailablePlaybackDevice {
  <#
  .SYNOPSIS
    First cached playback device in sorted-name order.
  .DESCRIPTION
    Returns $null when enumeration failed and an empty string when enumeration
    succeeded with nothing left, so the caller can name the real cause of a
    resolution that found no device.
  .PARAMETER CaptureDevice
    Device excluded from playback selection.
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param(
    [Parameter(Mandatory = $false)]
    [string]$CaptureDevice = ''
  )

  $names = Get-CamillaDSPAvailablePlaybackDeviceCache -CaptureDevice $CaptureDevice
  if ($null -eq $names) { return $null }
  $names = @($names)
  if ($names.Count -eq 0) { return '' }
  return [string]$names[0]
}

# --- Last saved default and push state ---

function Save-CamillaDSPLastDevice {
  <#
  .SYNOPSIS
    Records the device CamillaDSP accepted.
  .PARAMETER Device
    Device name; an empty value records nothing.
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [AllowEmptyString()]
    [string]$Device
  )

  if ([string]::IsNullOrEmpty($Device)) { return }
  $stateDir = Get-CamillaDSPStateDir
  New-Item -ItemType Directory -Path $stateDir -Force > $null
  Set-Content -Path (Join-Path -Path $stateDir -ChildPath 'last-device.txt') -Value $Device -NoNewline
}

function Get-CamillaDSPLastDevice {
  <#
  .SYNOPSIS
    Last recorded device, or $null when none was recorded.
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param()

  $path = Join-Path -Path (Get-CamillaDSPStateDir) -ChildPath 'last-device.txt'
  if (-not (Test-Path -Path $path -PathType Leaf)) { return $null }
  $content = Get-Content -Raw -Path $path
  if ([string]::IsNullOrWhiteSpace($content)) { return $null }
  return $content.Trim()
}

function Clear-CamillaDSPLastDevice {
  <#
  .SYNOPSIS
    Drops the recorded device.
  .DESCRIPTION
    Runs when enumeration succeeded and the saved device is genuinely gone, for
    example after state was copied from another machine. Without it every later
    tick retries the same doomed lookup.
  #>
  [CmdletBinding()]
  param()

  $path = Join-Path -Path (Get-CamillaDSPStateDir) -ChildPath 'last-device.txt'
  if (Test-Path -Path $path -PathType Leaf) {
    Remove-Item -Path $path -Force
  }
}

# --- Config resolution ---

# WHY: one broken topology would otherwise log the same line on every 5 s tick.
# Dot-sourcing puts this in the caller's script scope, so it survives a resident
# heartbeat and stays fresh in each test block; it is not a state file, because a
# restart should report the cause again.
$script:CamillaDSPLastWarnedCause = ''

function Write-CamillaDSPTopologyWarning {
  <#
  .SYNOPSIS
    Warns about a resolution failure, once per distinct cause.
  .DESCRIPTION
    A different cause warns again, and a successful resolution clears the record,
    so the next failure is reported.
  .PARAMETER Cause
    Cause key; the same key is not warned twice in a row.
  .PARAMETER Message
    Text to log when the cause is new.
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [string]$Cause,

    [Parameter(Mandatory)]
    [string]$Message
  )

  if ($script:CamillaDSPLastWarnedCause -eq $Cause) { return }
  $script:CamillaDSPLastWarnedCause = $Cause
  Write-NucleusWarning -CommandName 'camilladsp-deviceselect' -Message $Message
}

function Get-CamillaDSPLoopbackCaptureDevice {
  <#
  .SYNOPSIS
    Render endpoint the loopback capture reads, or an empty string.
  .DESCRIPTION
    In loopback mode CamillaDSP captures a render endpoint, so a null
    devices.capture.device means the default playback endpoint, which is the one
    applications play into. An explicit capture device is returned as is, since
    CamillaDSP opens that render endpoint instead. A config that is not loopback
    returns an empty string, because its capture device is not a render endpoint.
  .PARAMETER ConfigPath
    Config file to read.
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param(
    [Parameter(Mandatory)]
    [string]$ConfigPath
  )

  $config = (Get-Content -Raw -Path $ConfigPath) | ConvertFrom-Yaml
  $capture = $config.devices.capture
  if ($null -eq $capture -or $capture.loopback -ne $true) {
    return ''
  }

  $captureDevice = [string]$capture.device
  if (-not [string]::IsNullOrEmpty($captureDevice)) {
    return $captureDevice
  }

  $default = Get-CamillaDSPDefaultPlaybackDevice
  if ([string]::IsNullOrEmpty($default)) {
    return ''
  }
  return [string]$default
}

function ConvertTo-CamillaDSPPlaybackDeviceYaml {
  <#
  .SYNOPSIS
    Re-serializes a config with the playback device set.
  .DESCRIPTION
    The heartbeat pushes this instead of re-running detection, so the device it
    measured and the device it pushes are the same one. A loopback capture also
    gets its render endpoint written, so the pushed config names the endpoint
    instead of leaving CamillaDSP to resolve the default a second time.
  .PARAMETER ConfigPath
    Config file to patch.
  .PARAMETER Device
    Device to write into devices.playback.device.
  .PARAMETER CaptureDevice
    Render endpoint to write into devices.capture.device; ignored unless the
    config captures in loopback.
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param(
    [Parameter(Mandatory)]
    [string]$ConfigPath,

    [Parameter(Mandatory)]
    [AllowEmptyString()]
    [string]$Device,

    [Parameter(Mandatory = $false)]
    [AllowEmptyString()]
    [string]$CaptureDevice = ''
  )

  $config = (Get-Content -Raw -Path $ConfigPath) | ConvertFrom-Yaml
  $config.devices.playback.device = $Device
  # WHY: a capture that is not loopback has a capture-side name of its own, and
  # writing a render endpoint there would replace it.
  if (-not [string]::IsNullOrEmpty($CaptureDevice) -and $config.devices.capture.loopback -eq $true) {
    $config.devices.capture.device = $CaptureDevice
  }
  return ($config | ConvertTo-Yaml)
}

function Resolve-CamillaDSPPlaybackDevice {
  <#
  .SYNOPSIS
    Config text with the playback device resolved when it is null.
  .DESCRIPTION
    Resolution order: system default output, last saved device validated
    against the available list, first available device. A config that already
    sets a device is returned with its original text, so nothing is reserialized
    needlessly. A loopback capture holds the default playback endpoint, so that
    endpoint is excluded from every step, and a config whose only render
    endpoint is the capture source is returned unchanged with a warning naming
    the cause: a failed enumeration or the missing second endpoint.
  .PARAMETER ConfigPath
    Config file to resolve.
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param(
    [Parameter(Mandatory)]
    [string]$ConfigPath
  )

  $yaml = Get-Content -Raw -Path $ConfigPath
  $config = $yaml | ConvertFrom-Yaml

  if ($null -ne $config.devices.playback.device) {
    return $yaml
  }

  # A loopback capture reads a render endpoint, which is the device playback has
  # to avoid. A config with a capture-side name keeps the exclusion it had.
  $loopbackCaptureDevice = Get-CamillaDSPLoopbackCaptureDevice -ConfigPath $ConfigPath
  $captureDevice = if ([string]::IsNullOrEmpty($loopbackCaptureDevice)) {
    [string]$config.devices.capture.device
  } else {
    $loopbackCaptureDevice
  }

  $detected = Get-CamillaDSPDefaultPlaybackDevice
  if ($detected -eq $captureDevice) {
    $detected = $null
  }

  # Fallback 1: last saved default, validated against the available devices.
  if ([string]::IsNullOrEmpty($detected)) {
    $savedDevice = Get-CamillaDSPLastDevice
    if (-not [string]::IsNullOrEmpty($savedDevice) -and $savedDevice -ne $captureDevice) {
      $available = Get-CamillaDSPAvailablePlaybackDeviceCache -CaptureDevice $captureDevice -RequiredDevice $savedDevice
      if ($null -eq $available) {
        # Enumeration failed, so accept the saved device as best effort.
        $detected = $savedDevice
      } elseif (@($available) -contains $savedDevice) {
        $detected = $savedDevice
      } else {
        Clear-CamillaDSPLastDevice
      }
    }
  }

  # Fallback 2: first available device in sorted-name order.
  $enumerationFailed = $false
  if ([string]::IsNullOrEmpty($detected)) {
    $firstAvailable = Get-CamillaDSPFirstAvailablePlaybackDevice -CaptureDevice $captureDevice
    if ($null -eq $firstAvailable) {
      $enumerationFailed = $true
    } else {
      $detected = [string]$firstAvailable
    }
  }

  # Nothing available: pass through with the null device and say why.
  if ([string]::IsNullOrEmpty($detected)) {
    if ($enumerationFailed) {
      Write-CamillaDSPTopologyWarning -Cause 'enumeration-failed' -Message 'cannot enumerate playback devices: the Windows audio endpoint list is unavailable, so no playback device was selected'
    } else {
      Write-CamillaDSPTopologyWarning -Cause 'no-candidate' -Message 'no playback device available: the loopback capture takes the default playback endpoint, so this host needs a second playback endpoint'
    }
    return $yaml
  }

  $script:CamillaDSPLastWarnedCause = ''
  Save-CamillaDSPLastDevice -Device $detected
  return (ConvertTo-CamillaDSPPlaybackDeviceYaml -ConfigPath $ConfigPath -Device $detected -CaptureDevice $loopbackCaptureDevice)
}

function Get-CamillaDSPResolvedPlaybackDeviceName {
  <#
  .SYNOPSIS
    The device detection would select right now, or $null.
  .DESCRIPTION
    The heartbeat compares the live device against this value, so it re-pushes
    when the system default output changed.
  .PARAMETER ConfigPath
    Config file to resolve.
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param(
    [Parameter(Mandatory)]
    [string]$ConfigPath
  )

  if (-not (Test-Path -Path $ConfigPath -PathType Leaf)) {
    return $null
  }
  $resolved = Resolve-CamillaDSPPlaybackDevice -ConfigPath $ConfigPath
  $device = ($resolved | ConvertFrom-Yaml).devices.playback.device
  if ($null -eq $device) { return $null }
  return [string]$device
}
