<#
.SYNOPSIS
  Ensure CamillaDSP startup task is converged on Windows.

.DESCRIPTION
  Manages the CamillaDSP audio processor lifecycle for each managed user:
    1. Creates or removes a logon scheduled task that starts camilladsp.exe
       with the websocket API enabled.

  The config.yml is deployed to $HOME\.config\camilladsp\ by Invoke-CamillaDSPSetup.

.PARAMETER Enabled
  True applies the config and registers the startup task.  False removes the
  startup task.

.EXAMPLE
  Sync-CamillaDSPService -Enabled:$true

.EXAMPLE
  Sync-CamillaDSPService -Enabled:$false

.NOTES
  Environment variables:
    (none)

  Exit codes:
    0 on success; 1 on error.
#>
function Sync-CamillaDSPService {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [bool]$Enabled
  )

  $ErrorActionPreference = "Stop"
  $taskName = "NucleusCamillaDSP"
  $logDir = Get-NucleusLogDir
  $serviceLogDir = Join-Path -Path $logDir -ChildPath "camilladsp"
  $logFile = Join-Path -Path $serviceLogDir -ChildPath "combined.log"

  if (-not $Enabled) {
    $existingTask = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if ($null -ne $existingTask) {
      Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
      Write-Output "camilladsp: removed scheduled task '$taskName' (disabled)"
    }
    return
  }

  # Find the camilladsp binary.
  $camilladspCmd = Get-Command -Name "camilladsp.exe" -ErrorAction SilentlyContinue
  if ($null -eq $camilladspCmd) {
    Write-Output "camilladsp: binary not found in PATH; run Invoke-CamillaDSPSetup first"
    return
  }
  $camilladspBin = $camilladspCmd.Source

  # Read port from services.json (single source of truth).
  $repoRoot = Resolve-Path "$PSScriptRoot\..\..\..\..\.."
  $svc = Get-Content -Raw (Join-Path $repoRoot 'src/modules/services.json') -ErrorAction SilentlyContinue | ConvertFrom-Json
  $wsPort = if ($svc.camilladsp.network.websocket.port) { $svc.camilladsp.network.websocket.port } else { 1234 }

  $userId = if ([string]::IsNullOrWhiteSpace($env:USERDOMAIN)) {
    $env:USERNAME
  } else {
    "$($env:USERDOMAIN)\$($env:USERNAME)"
  }

  # Compute config path for wrapper script.
  $configPath = Join-Path -Path $HOME -ChildPath ".config\camilladsp\configs\config.yml"

  # Write the wrapper script that auto-applies config via WS API.
  $wrapperDir = Join-Path -Path $HOME -ChildPath ".config\camilladsp\bin"
  $null = New-Item -Path $wrapperDir -ItemType Directory -Force
  $wrapperScriptPath = Join-Path -Path $wrapperDir -ChildPath "autoconfig.ps1"
  $wrapperContent = @'
param(
  [Parameter(Mandatory)] [string] $CamillaDSPBin,
  [Parameter(Mandatory)] [int] $Port,
  [Parameter(Mandatory)] [string] $ConfigFile,
  [Parameter(Mandatory)] [string] $LogFile
)

$ErrorActionPreference = "Stop"

$stateFile = Join-Path -Path $HOME -ChildPath ".local\state\camilladsp\statefile.yml"
$null = New-Item -Path (Split-Path $stateFile -Parent) -ItemType Directory -Force

# Start camilladsp with --no_config (WS server only, no device).
$process = [System.Diagnostics.Process]::Start($CamillaDSPBin, "-p $Port --statefile `"$stateFile`" -w --no_config -o `"$LogFile`"")
if ($null -eq $process) { exit 1 }

# Assign camilladsp to a Windows Job Object with KILL_ON_JOB_CLOSE.
# When this wrapper exits (for any reason), the kernel automatically
# kills camilladsp too — no orphan processes on Windows.
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
  [void][JobObject]::AssignProcessToJobObject($job, $process.SafeHandle.DangerousGetHandle())
}

# Poll WS port and push config (up to ~15s).  Graceful if config file
# doesn't exist yet (first boot before Home Manager deploy).
for ($i = 0; $i -lt 30; $i++) {
  Start-Sleep -Milliseconds 500
  if (-not (Test-Path $ConfigFile)) { continue }
  try {
    $configYaml = Get-Content -Raw $ConfigFile
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
    $nc = Get-Content -Raw $ncf -ErrorAction SilentlyContinue | ConvertFrom-Json
    if ($null -ne $nc.camilladsp.heartbeat -and -not $nc.camilladsp.heartbeat) { return }
  }
  try {
    # Check current state — skip if already Running to avoid filling
    # CamillaDSP's bounded command channel (capacity 10).
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
    if ($state -eq "Running") { return }
  } catch {
    # Can't connect — will retry on next heartbeat.
    return
  }
  # Push config.
  try {
    $yaml = Get-Content -Raw $cf -ErrorAction Stop
    $msg = "{`"SetConfig`": $($yaml | ConvertTo-Json -Compress)}"
    $ws = [System.Net.WebSockets.ClientWebSocket]::new()
    $ws.ConnectAsync([System.Uri]"ws://127.0.0.1:$p", $ct).Wait()
    $ws.SendAsync([ArraySegment[byte]]::new([Text.Encoding]::UTF8.GetBytes($msg)), [WebSocketMessageType]::Text, $true, $ct).Wait()
    $ws.CloseAsync([CloseStatus]::NormalClosure, "done", $ct).Wait()
  } catch {
    # Device may be gone — retry on next heartbeat.
  }
}, ($ConfigFile, $Port, $nucleusCfgFile), 5000, 5000)

$process.WaitForExit()
$heartbeatTimer.Dispose()
'@
  Set-Content -Path $wrapperScriptPath -Value $wrapperContent -NoNewline

  $action = New-ScheduledTaskAction -Execute "pwsh.exe" -Argument "-WindowStyle Hidden -NoLogo -ExecutionPolicy Bypass -NoProfile -File `"$wrapperScriptPath`" -CamillaDSPBin `"$camilladspBin`" -Port $wsPort -ConfigFile `"$configPath`" -LogFile `"$logFile`""
  $trigger = New-ScheduledTaskTrigger -AtLogOn -User $userId
  $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
  $principal = New-ScheduledTaskPrincipal -UserId $userId -RunLevel Limited

  $existingTask = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
  if ($null -ne $existingTask) {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
  }

  Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force
  Write-Output "camilladsp: registered scheduled task '$taskName'"
}
