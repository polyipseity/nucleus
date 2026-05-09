# modules/windows/rdp.ps1 — Windows built-in Remote Desktop Protocol parity helpers.
#
# Manages TermService startup, firewall access, and cleanup with an explicit
# deconfiguration path when disabled.

function Sync-WindowsRdp {
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
    Whether Windows built-in RDP parity should be enforced. Mandatory: caller
    must explicitly choose true (apply managed RDP state) or false (cleanup).

  .EXAMPLE
    Sync-WindowsRdp -Enabled:$true

  .EXAMPLE
    Sync-WindowsRdp -Enabled:$false
  #>
  param(
    [Parameter(Mandatory)]
    [bool]$Enabled
  )

  $rdpService = Get-Service -Name 'TermService' -ErrorAction SilentlyContinue
  if ($null -eq $rdpService) {
    Write-Output "$($PSStyle.Formatting.Warning)Remote Desktop service (TermService) not found; skipping RDP convergence.$($PSStyle.Reset)"
    return
  }

  if ($Enabled) {
    # Start TermService automatically so RDP survives reboots and is
    # immediately available after apply without manual intervention.
    Set-Service -Name 'TermService' -StartupType Automatic
    Start-Service -Name 'TermService'
    # Open the built-in Windows firewall rules for RDP (TCP 3389 and UDP).
    # The rules already exist in every Windows install; we only enable them.
    Enable-NetFirewallRule -Name 'RemoteDesktop-UserMode-In-TCP'
    Enable-NetFirewallRule -Name 'RemoteDesktop-UserMode-In-UDP'
  }
  else {
    # Cleanup: stop the service and disable the firewall rules so no stale
    # RDP exposure remains when the feature is toggled off.
    if ((Get-Service -Name 'TermService').Status -ne 'Stopped') {
      Stop-Service -Name 'TermService'
    }
    Set-Service -Name 'TermService' -StartupType Manual
    Disable-NetFirewallRule -Name 'RemoteDesktop-UserMode-In-TCP'
    Disable-NetFirewallRule -Name 'RemoteDesktop-UserMode-In-UDP'
  }
}
