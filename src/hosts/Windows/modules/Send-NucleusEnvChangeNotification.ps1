<#
.SYNOPSIS
  Broadcast a WM_SETTINGCHANGE notification to all windows so that running
  processes pick up environment variable changes.
.DESCRIPTION
  Uses P/Invoke to call SendMessageTimeout with HWND_BROADCAST and
  WM_SETTINGCHANGE.  This is the standard Windows mechanism for notifying
  applications that environment variables have changed via
  SetEnvironmentVariable.

  After calling SetEnvironmentVariable, invoke this function so that GUI
  applications (Explorer, terminals, etc.) refresh their environment block
  without requiring a logoff/logon or reboot.

  Parameters must be named.
.EXAMPLE
  Send-NucleusEnvChangeNotification
.NOTES
  Cross-reference: docs/env-variable-registry.md
  This is the Windows equivalent of launchctl setenv on macOS and
  systemctl --user set-environment on Linux.
#>
function Send-NucleusEnvChangeNotification {
  [CmdletBinding()]
  param()

  # Define the P/Invoke signature once (static type is cached by PowerShell).
  $typeName = "Nucleus.SendMessageTimeout"
  if (-not ([System.Management.Automation.PSTypeName]$typeName).Type) {
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

namespace Nucleus {
  public static class SendMessageTimeout {
    [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Auto)]
    public static extern IntPtr SendMessageTimeout(
      IntPtr hWnd,
      uint msg,
      IntPtr wParam,
      string lParam,
      uint fuFlags,
      uint uTimeoutMillis,
      out IntPtr lpdwResult
    );
  }
}
"@
  }

  $HWND_BROADCAST = [IntPtr]0xFFFF
  $WM_SETTINGCHANGE = 0x001A
  $SMTO_ABORTIFHUNG = 0x0002
  $TIMEOUT_MS = 5000

  $result = [IntPtr]::Zero
  $ret = [Nucleus.SendMessageTimeout.SendMessageTimeout]::SendMessageTimeout(
    $HWND_BROADCAST,
    $WM_SETTINGCHANGE,
    [IntPtr]::Zero,
    "Environment",
    $SMTO_ABORTIFHUNG,
    $TIMEOUT_MS,
    [ref]$result
  )

  if ($ret -eq [IntPtr]::Zero) {
    Write-Warning "Send-NucleusEnvChangeNotification: failed to broadcast WM_SETTINGCHANGE (error $([System.Runtime.InteropServices.Marshal]::GetLastWin32Error()))"
  }
}
