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

# ── Exponential backoff ────────────────────────────────────────────────────
$baseSleep = 5
$maxSleep = 300
$currentSleep = $baseSleep

# ── Main loop (persistent daemon pattern) ──────────────────────────────────
while ($true) {
  # ── Runtime toggle from config.json ─────────────────────────────────────
  $nucleusCfgFile = Join-Path $HOME ".local\state\nucleus\config.json"
  if (Test-Path $nucleusCfgFile) {
    # check-suppress:suppression_doc: probe — no config file may not exist; $null check below handles absence
    $nc = Get-Content -Raw $nucleusCfgFile -ErrorAction SilentlyContinue | ConvertFrom-Json
    if ($null -ne $nc.camilladsp.heartbeat -and -not $nc.camilladsp.heartbeat) {
      Start-Sleep -Seconds $baseSleep
      continue
    }
  }

  $success = $false

  # ── Check current state — skip if already Running ──────────────────────
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
      $success = $true
    }
  } catch {
    # Can't connect — will retry with backoff.
    $null = $_
  }

  if (-not $success) {
    # ── Push config ──────────────────────────────────────────────────────
    if (Test-Path $ConfigFile) {
      try {
        $yaml = Get-Content -Raw $ConfigFile -ErrorAction Stop
        $msg = "{`"SetConfig`": $($yaml | ConvertTo-Json -Compress)}"
        $ws = [System.Net.WebSockets.ClientWebSocket]::new()
        $ws.ConnectAsync([System.Uri]"ws://127.0.0.1:$Port", $ct).Wait()
        $ws.SendAsync([ArraySegment[byte]]::new([Text.Encoding]::UTF8.GetBytes($msg)), [System.Net.WebSockets.WebSocketMessageType]::Text, $true, $ct).Wait()
        $ws.CloseAsync([System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure, "done", $ct).Wait()
        $success = $true
      } catch {
        # Device may be gone — retry with backoff.
        $null = $_
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
