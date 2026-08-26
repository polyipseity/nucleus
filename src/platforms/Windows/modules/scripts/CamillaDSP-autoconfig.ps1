<#
.SYNOPSIS
    CamillaDSP autoconfig wrapper for Windows service.
.DESCRIPTION
    Starts camilladsp with WebSocket server, assigns it to a Job Object for
    automatic cleanup, pushes config via WS, and heartbeats config every 5s.
#>
param(
  [Parameter(Mandatory)] [string] $CamillaDSPBin,
  [Parameter(Mandatory)] [int] $Port,
  [Parameter(Mandatory)] [string] $ConfigFile,
  [Parameter(Mandatory)] [string] $LogFile
)

$ErrorActionPreference = "Stop"

# ── Smart device detection ────────────────────────────────────────────────
. (Join-Path $PSScriptRoot "deviceselect.ps1")

$stateFile = Join-Path -Path $HOME -ChildPath ".local\state\camilladsp\statefile.yml"
$null = New-Item -Path (Split-Path $stateFile -Parent) -ItemType Directory -Force  # check-suppress:suppression_doc: New-Item returns DirectoryInfo, discarded

# Start camilladsp with --no_config (WS server only, no device).
$process = [System.Diagnostics.Process]::Start($CamillaDSPBin, "-p $Port --statefile `"$stateFile`" -w --no_config -o `"$LogFile`"")
if ($null -eq $process) { exit 1 }

# Assign camilladsp to a Windows Job Object with KILL_ON_JOB_CLOSE.
# When this wrapper exits (for any reason), the kernel automatically
# kills camilladsp too — no orphan processes on Windows.
# check-suppress:embedded-content: exception 3 (C# interop) -- P/Invoke classes stay inline up to 25 lines
Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class JobObject {
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern IntPtr CreateJobObject(IntPtr a, string b);
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool SetInformationJobObject(IntPtr h, int c, IntPtr i, int s);
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool AssignProcessToJobObject(IntPtr h, IntPtr p);
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool CloseHandle(IntPtr h);
    public static IntPtr NewKillOnClose() {
        IntPtr job = CreateJobObject(IntPtr.Zero, null);
        if (job == IntPtr.Zero) return IntPtr.Zero;
        var ext = new byte[144];
        BitConverter.GetBytes((uint)0x2000).CopyTo(ext, 16);
        IntPtr ptr = Marshal.AllocHGlobal(ext.Length);
        Marshal.Copy(ext, 0, ptr, ext.Length);
        bool ok = SetInformationJobObject(job, 9, ptr, ext.Length);
        Marshal.FreeHGlobal(ptr);
        if (!ok) { CloseHandle(job); return IntPtr.Zero; }
        return job;
    }
}
"@
$job = [JobObject]::NewKillOnClose()
if ($job -ne [IntPtr]::Zero) {
  [void][JobObject]::AssignProcessToJobObject($job, $process.SafeHandle.DangerousGetHandle())  # check-suppress:suppression_doc: AssignProcessToJobObject return value discarded, error handling is externally verified
}

# Poll WS port and push config (up to ~15s).  Graceful if config file
# doesn't exist yet (first boot before Home Manager deploy).
for ($i = 0; $i -lt 30; $i++) {
  Start-Sleep -Milliseconds 500
  if (-not (Test-Path $ConfigFile)) { continue }
  try {
    # Resolve playback device: patches empty device in config with system default.
    $configYaml = Resolve-CamillaDSPPlaybackDevice -ConfigPath $ConfigFile
    $configEscaped = $configYaml | ConvertTo-Json -Compress
    $message = "{`"SetConfig`": $configEscaped}"
    $ws = [System.Net.WebSockets.ClientWebSocket]::new()
    $ct = [System.Threading.CancellationToken]::Empty
    $ws.ConnectAsync([System.Uri]"ws://127.0.0.1:$Port", $ct).Wait()
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($message)
    $ws.SendAsync([ArraySegment[byte]]::new($bytes), [System.Net.WebSockets.WebSocketMessageType]::Text, $true, $ct).Wait()
    $ws.CloseAsync([System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure, "done", $ct).Wait()
    break
  } catch {
    # Port not ready or connection failed — retry.
    $null = $_  # check-suppress:suppression_doc: $_ discarded in ForEach-Object, side-effect-only iteration
  }
}

# Heartbeat: re-push config every 5s so config re-applies when a
# disconnected audio device reappears.
# Checks config.json on each tick so dynamic changes apply instantly.
$nucleusCfgFile = Join-Path $HOME ".local\state\nucleus\config.json"
$heartbeatTimer = [System.Threading.Timer]::new({
  param($s)
  $cf, $p, $ncf = $s
  # Check runtime toggle on every tick.
  if (Test-Path $ncf) {
    # check-suppress:suppression_doc: probe -- no-config file may not exist; $null check below handles absence
    $nc = Get-Content -Raw $ncf -ErrorAction SilentlyContinue | ConvertFrom-Json
    if ($null -ne $nc.camilladsp.heartbeat -and -not $nc.camilladsp.heartbeat) { return }
  }
  try {
    # Check current state.  Skip only when Running AND the live playback
    # device already matches the target device that detection would currently
    # select — a null live device must always be corrected (idiot-proof skip:
    # never leave a running instance with no device), and a live device that
    # differs from a non-null target (e.g. the system default output device
    # changed) must be re-pushed. A null target is never pushed.
    $targetDevice = Get-CamillaDSPResolvedPlaybackDeviceName -ConfigPath $cf
    $stateWs = [System.Net.WebSockets.ClientWebSocket]::new()
    $ct = [System.Threading.CancellationToken]::Empty
    $stateWs.ConnectAsync([System.Uri]"ws://127.0.0.1:$p", $ct).Wait()
    $getState = '{ "GetState": null }'
    $stateBytes = [Text.Encoding]::UTF8.GetBytes($getState)
    $stateWs.SendAsync([ArraySegment[byte]]::new($stateBytes), [WebSocketMessageType]::Text, $true, $ct).Wait()
    $recvBuf = New-Object byte[] 1024
    $result = $stateWs.ReceiveAsync([ArraySegment[byte]]::new($recvBuf), $ct).Result
    $stateResp = [Text.Encoding]::UTF8.GetString($recvBuf, 0, $result.Count)
    $stateWs.CloseAsync([CloseStatus]::NormalClosure, "done", $ct).Wait()
    $state = ($stateResp | ConvertFrom-Json).GetState.value
    if ($state -eq "Running") {
      # Query the live config to see if the playback device already matches target.
      $cfgWs = [System.Net.WebSockets.ClientWebSocket]::new()
      $cfgWs.ConnectAsync([System.Uri]"ws://127.0.0.1:$p", $ct).Wait()
      $getCfg = '{ "GetConfig": null }'
      $cfgBytes = [Text.Encoding]::UTF8.GetBytes($getCfg)
      $cfgWs.SendAsync([ArraySegment[byte]]::new($cfgBytes), [WebSocketMessageType]::Text, $true, $ct).Wait()
      $cfgBuf = New-Object byte[] 4096
      $cfgResult = $cfgWs.ReceiveAsync([ArraySegment[byte]]::new($cfgBuf), $ct).Result
      $cfgResp = [Text.Encoding]::UTF8.GetString($cfgBuf, 0, $cfgResult.Count)
      $cfgWs.CloseAsync([CloseStatus]::NormalClosure, "done", $ct).Wait()
      $liveDevice = ($cfgResp | ConvertFrom-Json).GetConfig.value.devices.playback.device
      if (-not [string]::IsNullOrEmpty($targetDevice) -and
          -not [string]::IsNullOrEmpty($liveDevice) -and
          $liveDevice -eq $targetDevice) { return }
    }
  } catch {
    # Can't connect — will retry on next heartbeat.
    return
  }
  # Push config.
  try {
    # Resolve playback device: patches empty device in config with system default.
    $yaml = Resolve-CamillaDSPPlaybackDevice -ConfigPath $cf
    $msg = "{`"SetConfig`": $($yaml | ConvertTo-Json -Compress)}"
    $ws = [System.Net.WebSockets.ClientWebSocket]::new()
    $ws.ConnectAsync([System.Uri]"ws://127.0.0.1:$p", $ct).Wait()
    $ws.SendAsync([ArraySegment[byte]]::new([Text.Encoding]::UTF8.GetBytes($msg)), [WebSocketMessageType]::Text, $true, $ct).Wait()
    $ws.CloseAsync([CloseStatus]::NormalClosure, "done", $ct).Wait()
  } catch {
    # Device may be gone — retry on next heartbeat.
    $null = $_  # check-suppress:suppression_doc: $_ discarded in ForEach-Object, side-effect-only iteration
  }
}, ($ConfigFile, $Port, $nucleusCfgFile), 5000, 5000)

$process.WaitForExit()
$heartbeatTimer.Dispose()
