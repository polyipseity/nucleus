<#
.SYNOPSIS
    CamillaDSP process supervisor for the Windows scheduled task.
.DESCRIPTION
    Starts camilladsp with the WebSocket server and no config, assigns it to a
    Job Object for automatic cleanup, and supervises that single process until it
    exits.

    This wrapper deliberately does not push a config. The heartbeat is the only
    pusher, which keeps a single writer for the audio graph and lets the
    camilladsp.enable toggle gate binding in exactly one place. Pushing here as
    well meant two writers racing at boot, each tearing down and rebuilding the
    audio graph. Mirrors camilladsp-run.sh on POSIX.
#>
param(
  [Parameter(Mandatory)] [string] $CamillaDSPBin,
  [Parameter(Mandatory)] [int] $Port,
  [Parameter(Mandatory)] [string] $LogFile
)

$ErrorActionPreference = "Stop"

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

$process.WaitForExit()
