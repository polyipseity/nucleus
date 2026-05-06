# modules/windows/rdp.ps1 — Windows built-in Remote Desktop Protocol parity helpers.
#
# Manages TermService startup, firewall access, and cleanup with an explicit
# deconfiguration path when disabled.

function Sync-NucleusWindowsRdp {
  <#
  .SYNOPSIS
    Converges Windows Remote Desktop (RDP) service state and firewall access.

  .DESCRIPTION
    Ensures the Windows built-in RDP server (TermService) is running and the
    firewall rule permits inbound connections on TCP 3389, completing the
    three-protocol remote-desktop baseline alongside Chrome Remote Desktop and
    Parsec:
      - Service startup type: Automatic
      - Service state: Running
      - Firewall rule: RemoteDesktop-UserMode-In-TCP enabled
      - Firewall rule: RemoteDesktop-UserMode-In-UDP enabled

    The registry key fDenyTSConnections is managed declaratively via
    system.dsc.yml rather than here, so this function only controls service
    lifecycle and firewall state.

    When disabled, the function reverses managed state:
      - Stops TermService and sets startup type to Manual
      - Disables the RemoteDesktop-UserMode-In-TCP firewall rule
      - Disables the RemoteDesktop-UserMode-In-UDP firewall rule

  .PARAMETER Enabled
    Whether Windows built-in RDP parity should be enforced. False applies cleanup.

  .EXAMPLE
    Sync-NucleusWindowsRdp -Enabled:$true

  .EXAMPLE
    Sync-NucleusWindowsRdp -Enabled:$false
  #>
  param(
    [Parameter()]
    [bool]$Enabled = $true
  )

  $rdpService = Get-Service -Name 'TermService' -ErrorAction SilentlyContinue
  if ($null -eq $rdpService) {
    Write-Host 'Remote Desktop service (TermService) not found; skipping RDP convergence.' -ForegroundColor Yellow
    return
  }

  if ($Enabled) {
    # Start TermService automatically so RDP survives reboots and is
    # immediately available after apply without manual intervention.
    Set-Service -Name 'TermService' -StartupType Automatic
    Start-Service -Name 'TermService' -ErrorAction SilentlyContinue
    # Open the built-in Windows firewall rules for RDP (TCP 3389 and UDP).
    # The rules already exist in every Windows install; we only enable them.
    Enable-NetFirewallRule -Name 'RemoteDesktop-UserMode-In-TCP' -ErrorAction SilentlyContinue
    Enable-NetFirewallRule -Name 'RemoteDesktop-UserMode-In-UDP' -ErrorAction SilentlyContinue
  }
  else {
    # Cleanup: stop the service and disable the firewall rules so no stale
    # RDP exposure remains when the feature is toggled off.
    Stop-Service -Name 'TermService' -ErrorAction SilentlyContinue
    Set-Service -Name 'TermService' -StartupType Manual
    Disable-NetFirewallRule -Name 'RemoteDesktop-UserMode-In-TCP' -ErrorAction SilentlyContinue
    Disable-NetFirewallRule -Name 'RemoteDesktop-UserMode-In-UDP' -ErrorAction SilentlyContinue
  }
}
