<#
.SYNOPSIS
  Persistent-loop heartbeat for CamillaDSP on Windows.

.DESCRIPTION
  Pushes the current config if camilladsp is not in "Running" state.
  Runs indefinitely with exponential backoff (persistent daemon pattern —
  launched by scheduled task AtLogOn).
  Mirrors camilladsp-heartbeat.sh (POSIX counterpart).

  Base delay: 5 s, max delay: 300 s.
  Resets to base on success, doubles on failure.
#>

param(
  [Parameter(Mandatory = $false)]
  [int]$Port = 1234,

  [Parameter(Mandatory = $false)]
  [string]$ConfigFile = "$HOME\.config\camilladsp\configs\config.yml"
)

$ErrorActionPreference = "Stop"

# ── Smart device detection ────────────────────────────────────────────────
. "$PSScriptRoot/camilladsp-deviceselect.ps1"

# ── Exponential backoff ────────────────────────────────────────────────────
$baseSleep = 5
$maxSleep = 300
$currentSleep = $baseSleep

# ── Main loop (persistent daemon pattern) ──────────────────────────────────
while ($true) {
  # ── Runtime toggle from config.json ─────────────────────────────────────
  $nucleusCfgFile = Join-Path $HOME ".local\state\nucleus\config.json"
  if (Test-Path $nucleusCfgFile) {
    # check-suppress:suppression_doc: probe -- no config file may not exist; $null check below handles absence
    $nc = Get-Content -Raw $nucleusCfgFile -ErrorAction SilentlyContinue | ConvertFrom-Json
    if ($null -ne $nc.camilladsp.heartbeat -and -not $nc.camilladsp.heartbeat) {
      Start-Sleep -Seconds $baseSleep
      continue
    }
  }

  $success = $false

  # ── Check current state — skip only when Running AND live device matches target ──
  # The target device is what detection would currently select. When the system
  # default output device changes, the target differs from the live device, so
  # the config must be re-pushed. A null target is never pushed (it would set
  # the device to null).
  $targetDevice = $null
  if (Test-Path $ConfigFile) {
    $targetDevice = Get-CamillaDSPResolvedPlaybackDeviceName -ConfigPath $ConfigFile
  }
  try {
    $stateWs = [System.Net.WebSockets.ClientWebSocket]::new()
    $ct = [System.Threading.CancellationToken]::Empty
    $stateWs.ConnectAsync([System.Uri]"ws://127.0.0.1:$Port", $ct).Wait()
    $getState = '{ "GetState": null }'
    $stateBytes = [Text.Encoding]::UTF8.GetBytes($getState)
    $stateWs.SendAsync([ArraySegment[byte]]::new($stateBytes), [System.Net.WebSockets.WebSocketMessageType]::Text, $true, $ct).Wait()
    $recvBuf = New-Object byte[] 1024
    $result = $stateWs.ReceiveAsync([ArraySegment[byte]]::new($recvBuf), $ct).Result
    $stateResp = [Text.Encoding]::UTF8.GetString($recvBuf, 0, $result.Count)
    $stateWs.CloseAsync([System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure, "done", $ct).Wait()
    $state = ($stateResp | ConvertFrom-Json).GetState.value
    if ($state -eq "Running") {
      # Query the live config to see if the playback device already matches target.
      $cfgWs = [System.Net.WebSockets.ClientWebSocket]::new()
      $cfgWs.ConnectAsync([System.Uri]"ws://127.0.0.1:$Port", $ct).Wait()
      $getCfg = '{ "GetConfig": null }'
      $cfgBytes = [Text.Encoding]::UTF8.GetBytes($getCfg)
      $cfgWs.SendAsync([ArraySegment[byte]]::new($cfgBytes), [System.Net.WebSockets.WebSocketMessageType]::Text, $true, $ct).Wait()
      $cfgBuf = New-Object byte[] 4096
      $cfgResult = $cfgWs.ReceiveAsync([ArraySegment[byte]]::new($cfgBuf), $ct).Result
      $cfgResp = [Text.Encoding]::UTF8.GetString($cfgBuf, 0, $cfgResult.Count)
      $cfgWs.CloseAsync([System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure, "done", $ct).Wait()
      $liveDevice = ($cfgResp | ConvertFrom-Json).GetConfig.value.devices.playback.device
      # Skip only when a non-null target is already live. A null target is never
      # pushed; a live device that differs from a non-null target must be corrected.
      if (-not [string]::IsNullOrEmpty($targetDevice) -and
          -not [string]::IsNullOrEmpty($liveDevice) -and
          $liveDevice -eq $targetDevice) {
        $success = $true
      }
    }
  } catch {
    # Can't connect — will retry with backoff.
    $null = $_  # check-suppress:suppression_doc: $_ discarded in ForEach-Object, side-effect-only iteration
  }

  if (-not $success) {
    # ── Push config ──────────────────────────────────────────────────────
    if (Test-Path $ConfigFile) {
      try {
        # Resolve playback device: patches empty device in config with system default.
        $yaml = Resolve-CamillaDSPPlaybackDevice -ConfigPath $ConfigFile
        $msg = "{`"SetConfig`": $($yaml | ConvertTo-Json -Compress)}"
        $ws = [System.Net.WebSockets.ClientWebSocket]::new()
        $ws.ConnectAsync([System.Uri]"ws://127.0.0.1:$Port", $ct).Wait()
        $ws.SendAsync([ArraySegment[byte]]::new([Text.Encoding]::UTF8.GetBytes($msg)), [System.Net.WebSockets.WebSocketMessageType]::Text, $true, $ct).Wait()
        $ws.CloseAsync([System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure, "done", $ct).Wait()
        $success = $true
      } catch {
        # Device may be gone — retry with backoff.
        $null = $_  # check-suppress:suppression_doc: $_ discarded in ForEach-Object, side-effect-only iteration
      }
    }
  }

  if ($success) {
    $currentSleep = $baseSleep
  } else {
    $currentSleep = [Math]::Min($currentSleep * 2, $maxSleep)
  }

  Start-Sleep -Seconds $currentSleep
}
