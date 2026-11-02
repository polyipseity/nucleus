<#
.SYNOPSIS
  Resident CamillaDSP playback-device heartbeat for Windows.

.DESCRIPTION
  One websocket connection lives for the whole loop. Each tick decides, in this
  order, whether CamillaDSP needs the config pushed:

  - endpoint absent: a TCP connect fails, so the tick costs no probe and no
    push, sleeps AbsentSleep, and resets the backoff rather than growing it.
  - connected but not "Running": push, with the wait doubling from 5 s up to
    300 s on failure.
  - "Running": push only when the live device differs from the target or the
    config fingerprint changed since the last accepted push.

  camilladsp.heartbeat gates the loop and camilladsp.enable gates device
  binding. Both default to on, and an explicit false is respected.

.PARAMETER Port
  CamillaDSP websocket API port.

.PARAMETER ConfigFile
  Config file the heartbeat pushes.
#>

param(
  [Parameter(Mandatory = $false)]
  [int]$Port = 1234,

  [Parameter(Mandatory = $false)]
  [string]$ConfigFile = "$HOME\.config\camilladsp\configs\config.yml"
)

$ErrorActionPreference = "Stop"

# WHY: messages reach stderr.log through the scheduled-task wrapper, so they go
# through the shared formatter to keep the F1 "camilladsp-heartbeat: warning:"
# prefix rather than the host's bare "WARNING:" line.
Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..\..\platforms\Windows\modules\Format-NucleusOutput.psm1') -Force

. "$PSScriptRoot/camilladsp-deviceselect.ps1"

$baseSleep = 5
$maxSleep = 300
# An absent endpoint gets its own cadence: a cheap TCP connect is the only work
# a tick does, so the loop still notices CamillaDSP starting inside ten seconds.
$absentSleep = 10
$sleepSeconds = $baseSleep

$script:CamillaDSPWebSocket = $null

function Test-CamillaDSPEndpoint {
  <#
  .SYNOPSIS
    True when something accepts TCP connections on the CamillaDSP port.
  .DESCRIPTION
    A connect-and-close probe answers one question cheaply: is CamillaDSP up.
    It keeps a stopped instance from paying for a websocket connect, a state
    query and a config push on every tick.
  .PARAMETER EndpointPort
    CamillaDSP websocket API port.
  #>
  [CmdletBinding()]
  [OutputType([bool])]
  param(
    [Parameter(Mandatory)]
    [int]$EndpointPort
  )

  $client = [System.Net.Sockets.TcpClient]::new()
  try {
    $connect = $client.ConnectAsync('127.0.0.1', $EndpointPort)
    if (-not $connect.Wait(1000)) { return $false }
    return $client.Connected
  } catch {
    # Refused or unreachable: the endpoint is absent.
    return $false
  } finally {
    $client.Dispose()
  }
}

function Connect-CamillaDSPWebSocket {
  <#
  .SYNOPSIS
    Opens the websocket the loop holds for its lifetime.
  .PARAMETER EndpointPort
    CamillaDSP websocket API port.
  #>
  [CmdletBinding()]
  [OutputType([System.Net.WebSockets.ClientWebSocket])]
  param(
    [Parameter(Mandatory)]
    [int]$EndpointPort
  )

  $socket = [System.Net.WebSockets.ClientWebSocket]::new()
  $timeout = [System.Threading.CancellationTokenSource]::new([TimeSpan]::FromSeconds(3))
  try {
    # WHY the redirect: awaiting a void Task still emits a VoidTaskResult into
    # the pipeline, which would leave the caller holding that instead of the socket.
    $socket.ConnectAsync([Uri]"ws://127.0.0.1:$EndpointPort", $timeout.Token).GetAwaiter().GetResult() > $null
    return $socket
  } catch {
    $socket.Dispose()
    throw
  } finally {
    $timeout.Dispose()
  }
}

function Close-CamillaDSPWebSocket {
  <#
  .SYNOPSIS
    Drops the current connection so the next request reconnects.
  #>
  [CmdletBinding()]
  param()

  if ($null -eq $script:CamillaDSPWebSocket) { return }
  try {
    $script:CamillaDSPWebSocket.Dispose()
  } catch {
    Write-NucleusWarning -CommandName 'camilladsp-heartbeat' -Message "closing the stale websocket failed: $($_.Exception.Message)"
  }
  $script:CamillaDSPWebSocket = $null
}

function Invoke-CamillaDSPRequest {
  <#
  .SYNOPSIS
    Sends one request over the persistent websocket and returns the response.
  .DESCRIPTION
    The connection is opened by the first request and reused by every later
    one, so a tick no longer runs a connect, send and close cycle per request.
    A transport failure resets the socket and rethrows, and the next request
    reconnects.
  .PARAMETER EndpointPort
    CamillaDSP websocket API port.
  .PARAMETER Payload
    JSON request body.
  #>
  [CmdletBinding()]
  [OutputType([hashtable])]
  param(
    [Parameter(Mandatory)]
    [int]$EndpointPort,

    [Parameter(Mandatory)]
    [string]$Payload
  )

  if ($null -eq $script:CamillaDSPWebSocket) {
    $script:CamillaDSPWebSocket = Connect-CamillaDSPWebSocket -EndpointPort $EndpointPort
  }
  $socket = $script:CamillaDSPWebSocket

  $timeout = [System.Threading.CancellationTokenSource]::new([TimeSpan]::FromSeconds(10))
  try {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Payload)
    $socket.SendAsync(
      [System.ArraySegment[byte]]::new($bytes),
      [System.Net.WebSockets.WebSocketMessageType]::Text,
      $true,
      $timeout.Token
    ).GetAwaiter().GetResult() > $null

    # A large config arrives fragmented, so one ReceiveAsync is not a whole
    # message: keep receiving until EndOfMessage and double the buffer whenever
    # a fragment fills it.
    $buffer = [byte[]]::new(4096)
    $stream = [System.IO.MemoryStream]::new()
    try {
      do {
        $result = $socket.ReceiveAsync(
          [System.ArraySegment[byte]]::new($buffer),
          $timeout.Token
        ).GetAwaiter().GetResult()
        if ($result.MessageType -eq [System.Net.WebSockets.WebSocketMessageType]::Close) {
          throw "camilladsp closed the websocket ($($result.CloseStatus))"
        }
        $stream.Write($buffer, 0, $result.Count)
        if (-not $result.EndOfMessage -and $result.Count -eq $buffer.Length) {
          $buffer = [byte[]]::new($buffer.Length * 2)
        }
      } until ($result.EndOfMessage)
      return ([System.Text.Encoding]::UTF8.GetString($stream.ToArray()) | ConvertFrom-Json -AsHashtable)
    } finally {
      $stream.Dispose()
    }
  } catch {
    Close-CamillaDSPWebSocket
    throw
  } finally {
    $timeout.Dispose()
  }
}

function Get-CamillaDSPRunState {
  <#
  .SYNOPSIS
    CamillaDSP processing state, or an empty string when it is unknown.
  .PARAMETER EndpointPort
    CamillaDSP websocket API port.
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param(
    [Parameter(Mandatory)]
    [int]$EndpointPort
  )

  $response = Invoke-CamillaDSPRequest -EndpointPort $EndpointPort -Payload (@{ GetState = $null } | ConvertTo-Json -Compress)
  if ($null -eq $response -or $null -eq $response.GetState) { return '' }
  return [string]$response.GetState.value
}

function Get-CamillaDSPLiveDevice {
  <#
  .SYNOPSIS
    Playback device of the config CamillaDSP is running, or an empty string.
  .PARAMETER EndpointPort
    CamillaDSP websocket API port.
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param(
    [Parameter(Mandatory)]
    [int]$EndpointPort
  )

  $response = Invoke-CamillaDSPRequest -EndpointPort $EndpointPort -Payload (@{ GetConfig = $null } | ConvertTo-Json -Compress)
  if ($null -eq $response -or $null -eq $response.GetConfig) { return '' }
  $text = [string]$response.GetConfig.value
  if ([string]::IsNullOrEmpty($text)) { return '' }

  try {
    $config = $text | ConvertFrom-Yaml
  } catch {
    Write-NucleusWarning -CommandName 'camilladsp-heartbeat' -Message "live config is not valid YAML: $($_.Exception.Message)"
    return ''
  }

  $device = $config.devices.playback.device
  if ($null -eq $device) { return '' }
  return [string]$device
}

function Test-CamillaDSPNeedsPush {
  <#
  .SYNOPSIS
    Whether CamillaDSP needs the config pushed this tick.
  .DESCRIPTION
    A null target is skipped while CamillaDSP is Running: there is no device to
    compare, and a push would only repeat the running config. While it is not
    Running the decision is a push whatever the target, so the initial config is
    delivered; Send-CamillaDSPConfig then refuses a loopback config whose
    playback device is empty or is the capture endpoint, or whose capture
    endpoint is unresolved, so a config that would capture its own output never
    binds.
  .PARAMETER RunState
    Value of GetState.
  .PARAMETER LiveDevice
    Playback device of the running config.
  .PARAMETER TargetDevice
    Device resolution selects right now.
  .PARAMETER ConfigChanged
    Whether the config differs from the last accepted push.
  #>
  [CmdletBinding()]
  [OutputType([bool])]
  param(
    [Parameter(Mandatory)]
    [AllowEmptyString()]
    [string]$RunState,

    [Parameter(Mandatory)]
    [AllowEmptyString()]
    [string]$LiveDevice,

    [Parameter(Mandatory)]
    [AllowEmptyString()]
    [string]$TargetDevice,

    [Parameter(Mandatory)]
    [bool]$ConfigChanged
  )

  if ($RunState -eq 'Running' -and [string]::IsNullOrEmpty($TargetDevice)) {
    return $false
  }
  if ($RunState -eq 'Running' -and
      -not [string]::IsNullOrEmpty($LiveDevice) -and
      $LiveDevice -eq $TargetDevice -and
      -not $ConfigChanged) {
    return $false
  }
  return $true
}

function Get-CamillaDSPConfigFingerprint {
  <#
  .SYNOPSIS
    SHA256 over the config bytes, the resolved playback device, and the resolved
    capture device.
  .DESCRIPTION
    The device names are part of the hash because the config stores them as null,
    so a device change would otherwise look like no change. A loopback capture
    follows the default playback endpoint, which can change with the config bytes
    untouched, so the capture name needs its own separator.
  .PARAMETER ConfigPath
    Config file whose bytes are hashed.
  .PARAMETER TargetDevice
    Device resolution selects right now.
  .PARAMETER CaptureDevice
    Capture endpoint resolution selects right now.
  #>
  [CmdletBinding()]
  [OutputType([string])]
  param(
    [Parameter(Mandatory)]
    [string]$ConfigPath,

    [Parameter(Mandatory)]
    [AllowEmptyString()]
    [string]$TargetDevice,

    [Parameter(Mandatory = $false)]
    [AllowEmptyString()]
    [string]$CaptureDevice = ''
  )

  $segments = @(
    [System.IO.File]::ReadAllBytes($ConfigPath),
    [System.Text.Encoding]::UTF8.GetBytes("`n--playback-device--`n"),
    [System.Text.Encoding]::UTF8.GetBytes($TargetDevice),
    [System.Text.Encoding]::UTF8.GetBytes("`n--capture-device--`n"),
    [System.Text.Encoding]::UTF8.GetBytes($CaptureDevice)
  )

  $length = 0
  foreach ($segment in $segments) {
    $length += $segment.Length
  }
  $combined = [byte[]]::new($length)
  $offset = 0
  foreach ($segment in $segments) {
    [System.Array]::Copy($segment, 0, $combined, $offset, $segment.Length)
    $offset += $segment.Length
  }

  $sha = [System.Security.Cryptography.SHA256]::Create()
  try {
    return [System.Convert]::ToHexString($sha.ComputeHash($combined)).ToLowerInvariant()
  } finally {
    $sha.Dispose()
  }
}

function Test-CamillaDSPConfigChanged {
  <#
  .SYNOPSIS
    Whether the config differs from the last push CamillaDSP accepted.
  .DESCRIPTION
    A missing last-push.txt counts as changed, so the first tick after boot
    always pushes. Comparing the fingerprint rather than the config text is what
    lets camillagui edits survive a tick that has nothing to do.
  .PARAMETER ConfigPath
    Config file to fingerprint.
  .PARAMETER TargetDevice
    Device resolution selects right now.
  .PARAMETER CaptureDevice
    Capture endpoint resolution selects right now.
  #>
  [CmdletBinding()]
  [OutputType([bool])]
  param(
    [Parameter(Mandatory)]
    [string]$ConfigPath,

    [Parameter(Mandatory)]
    [AllowEmptyString()]
    [string]$TargetDevice,

    [Parameter(Mandatory = $false)]
    [AllowEmptyString()]
    [string]$CaptureDevice = ''
  )

  $lastPushFile = Join-Path -Path (Get-CamillaDSPStateDir) -ChildPath 'last-push.txt'
  if (-not (Test-Path -Path $lastPushFile -PathType Leaf)) { return $true }

  $recorded = (Get-Content -Raw -Path $lastPushFile).Trim()
  return $recorded -ne (Get-CamillaDSPConfigFingerprint -ConfigPath $ConfigPath -TargetDevice $TargetDevice -CaptureDevice $CaptureDevice)
}

function Save-CamillaDSPLastPush {
  <#
  .SYNOPSIS
    Records the fingerprint of a config CamillaDSP accepted.
  .PARAMETER Fingerprint
    Fingerprint to record; an empty value records nothing.
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [AllowEmptyString()]
    [string]$Fingerprint
  )

  if ([string]::IsNullOrEmpty($Fingerprint)) { return }
  $stateDir = Get-CamillaDSPStateDir
  New-Item -ItemType Directory -Path $stateDir -Force > $null
  Set-Content -Path (Join-Path -Path $stateDir -ChildPath 'last-push.txt') -Value $Fingerprint -NoNewline
}

# WHY: a refused push is retried on every tick while the topology stays broken,
# so the refusal is logged once per distinct reason instead of once per tick.
# This is the heartbeat's own scope, which outlives the loop's iterations.
$script:CamillaDSPLastPushRefusal = ''

function Write-CamillaDSPPushRefusalWarning {
  <#
  .SYNOPSIS
    Warns about a refused push, once per distinct reason.
  .DESCRIPTION
    A different reason warns again, and an accepted push clears the record, so
    the next refusal is reported.
  .PARAMETER Cause
    Reason key; the same key is not warned twice in a row.
  .PARAMETER Message
    Text to log when the reason is new.
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [string]$Cause,

    [Parameter(Mandatory)]
    [string]$Message
  )

  if ($script:CamillaDSPLastPushRefusal -eq $Cause) { return }
  $script:CamillaDSPLastPushRefusal = $Cause
  Write-NucleusWarning -CommandName 'camilladsp-heartbeat' -Message $Message
}

function Send-CamillaDSPConfig {
  <#
  .SYNOPSIS
    Pushes the config, returning whether CamillaDSP accepted it.
  .DESCRIPTION
    A target device is patched into the config directly, so the device that was
    measured is the device that gets pushed. State is recorded only after
    CamillaDSP answers "Ok"; a rejection drops the device cache, because the
    resolved device is probably gone even though the cache still lists it. A
    loopback capture is never pushed onto a device it would feed from: an empty
    playback device binds the system default output, which is the loopback
    capture endpoint, an unresolved capture endpoint cannot be proven different
    from that output, and a playback device equal to the capture endpoint makes
    CamillaDSP capture its own output. A capture that is not loopback is pushed
    even with an empty playback device, because CamillaDSP then binds its own
    default output and nothing feeds it back. The unresolved-endpoint and
    capture-equals-playback refusals each name a reason and warn once per
    reason; the empty-device refusal names none and keeps the resolver's own
    warning.
  .PARAMETER EndpointPort
    CamillaDSP websocket API port.
  .PARAMETER ConfigPath
    Config file to push.
  .PARAMETER TargetDevice
    Device to push, or an empty value to resolve the config first.
  .PARAMETER CaptureDevice
    Capture endpoint the tick resolved: written alongside the target device, and
    the endpoint the push must not be pointed back into. Empty means unresolved.
  #>
  [CmdletBinding()]
  [OutputType([bool])]
  param(
    [Parameter(Mandatory)]
    [int]$EndpointPort,

    [Parameter(Mandatory)]
    [string]$ConfigPath,

    [Parameter(Mandatory)]
    [AllowEmptyString()]
    [string]$TargetDevice,

    [Parameter(Mandatory = $false)]
    [AllowEmptyString()]
    [string]$CaptureDevice = ''
  )

  $yaml = if ([string]::IsNullOrEmpty($TargetDevice)) {
    Resolve-CamillaDSPPlaybackDevice -ConfigPath $ConfigPath
  } else {
    ConvertTo-CamillaDSPPlaybackDeviceYaml -ConfigPath $ConfigPath -Device $TargetDevice -CaptureDevice $CaptureDevice
  }

  $pushedConfig = $yaml | ConvertFrom-Yaml
  $pushedDevice = [string]$pushedConfig.devices.playback.device

  # WHY: the capture endpoint is the one device playback has to avoid, and the
  # comparison uses the endpoint the tick resolved. Resolving it again here could
  # observe a different default and prove nothing. Only a loopback capture reads
  # a render endpoint, so only then can playback be pointed back into it; a
  # capture with a capture-side device of its own cannot be what a null playback
  # device binds, and CamillaDSP resolves that null to its own default output.
  if ($pushedConfig.devices.capture.loopback -eq $true) {
    # WHY: an empty playback device makes CamillaDSP bind the system default
    # output, which is the loopback capture endpoint whenever capture is that
    # loopback, so only then would the config feed its own output back as input.
    # The resolver has already warned about the cause.
    if ([string]::IsNullOrEmpty($pushedDevice)) {
      return $false
    }
    if ([string]::IsNullOrEmpty($CaptureDevice)) {
      Write-CamillaDSPPushRefusalWarning -Cause 'unknown-capture' -Message 'not pushing: the loopback capture endpoint is unresolved because no default playback endpoint was found, so playback cannot be proven different from it'
      return $false
    }
    if ($pushedDevice -eq $CaptureDevice) {
      Write-CamillaDSPPushRefusalWarning -Cause 'capture-equals-playback' -Message "not pushing: playback device '$pushedDevice' is also the capture endpoint '$CaptureDevice', so CamillaDSP would capture its own output"
      return $false
    }
  }

  $payload = @{ SetConfig = $yaml } | ConvertTo-Json -Compress
  $response = Invoke-CamillaDSPRequest -EndpointPort $EndpointPort -Payload $payload
  if ($null -eq $response.SetConfig -or $response.SetConfig.result -ne 'Ok') {
    Clear-CamillaDSPDeviceCache
    return $false
  }

  $script:CamillaDSPLastPushRefusal = ''
  Save-CamillaDSPLastDevice -Device $pushedDevice
  Save-CamillaDSPLastPush -Fingerprint (Get-CamillaDSPConfigFingerprint -ConfigPath $ConfigPath -TargetDevice $pushedDevice -CaptureDevice $CaptureDevice)
  return $true
}

function Get-CamillaDSPRuntimeToggle {
  <#
  .SYNOPSIS
    The camilladsp heartbeat and binding toggles.
  .DESCRIPTION
    Both default to on when the runtime config or the camilladsp block is
    absent, and an explicit false is respected. An unreadable file warns and
    leaves both on, as the Python daemon does.
  #>
  [CmdletBinding()]
  [OutputType([hashtable])]
  param()

  $toggle = @{ Heartbeat = $true; Binding = $true }
  $configPath = Join-Path -Path $HOME -ChildPath '.local/state/nucleus/config.json'
  if (-not (Test-Path -Path $configPath -PathType Leaf)) { return $toggle }

  try {
    $config = Get-Content -Raw -Path $configPath | ConvertFrom-Json -AsHashtable
  } catch {
    Write-NucleusWarning -CommandName 'camilladsp-heartbeat' -Message "cannot read ${configPath}: $($_.Exception.Message)"
    return $toggle
  }

  if ($null -eq $config) { return $toggle }
  $section = $config['camilladsp']
  if ($section -isnot [System.Collections.IDictionary]) { return $toggle }

  # `-or` would collapse an explicit false, so compare against null.
  if ($null -ne $section['heartbeat']) { $toggle.Heartbeat = [bool]$section['heartbeat'] }
  if ($null -ne $section['enable']) { $toggle.Binding = [bool]$section['enable'] }
  return $toggle
}

while ($true) {
  $toggle = Get-CamillaDSPRuntimeToggle
  if (-not $toggle.Heartbeat -or -not $toggle.Binding) {
    # WHY: the loop keeps running so the websocket API stays up for camillagui,
    # but nothing binds a device. An open capture device lights the OS
    # microphone privacy indicator, which is the cost these toggles avoid.
    Start-Sleep -Seconds $baseSleep
    continue
  }

  if (-not (Test-CamillaDSPEndpoint -EndpointPort $Port)) {
    Close-CamillaDSPWebSocket
    $sleepSeconds = $baseSleep
    Start-Sleep -Seconds $absentSleep
    continue
  }

  $success = $false
  try {
    $runState = Get-CamillaDSPRunState -EndpointPort $Port
    $liveDevice = ''
    if ($runState -eq 'Running') {
      $liveDevice = Get-CamillaDSPLiveDevice -EndpointPort $Port
    }

    $targetDevice = ''
    $captureDevice = ''
    $configChanged = $true
    if (Test-Path -Path $ConfigFile -PathType Leaf) {
      $targetDevice = [string](Get-CamillaDSPResolvedPlaybackDeviceName -ConfigPath $ConfigFile)
      $captureDevice = [string](Get-CamillaDSPLoopbackCaptureDevice -ConfigPath $ConfigFile)
      $configChanged = Test-CamillaDSPConfigChanged -ConfigPath $ConfigFile -TargetDevice $targetDevice -CaptureDevice $captureDevice
    }

    if (Test-CamillaDSPNeedsPush -RunState $runState -LiveDevice $liveDevice -TargetDevice $targetDevice -ConfigChanged $configChanged) {
      $success = Send-CamillaDSPConfig -EndpointPort $Port -ConfigPath $ConfigFile -TargetDevice $targetDevice -CaptureDevice $captureDevice
    } else {
      $success = $true
    }
  } catch {
    Write-NucleusWarning -CommandName 'camilladsp-heartbeat' -Message "tick failed: $($_.Exception.Message)"
  }

  $sleepSeconds = if ($success) { $baseSleep } else { [Math]::Min($sleepSeconds * 2, $maxSleep) }
  Start-Sleep -Seconds $sleepSeconds
}
