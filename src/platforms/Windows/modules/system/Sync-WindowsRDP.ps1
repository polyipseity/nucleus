<#
.SYNOPSIS
  Windows built-in Remote Desktop Protocol parity helpers.

.DESCRIPTION
  Manages TermService startup, firewall access, and cleanup with an explicit
  deconfiguration path when disabled.

.NOTES
  Environment variables:
    (none)    No environment variables used.

  Exit codes:
    This module does not emit exit codes.
#>
function Sync-WindowsRDP {
  <#
  .SYNOPSIS
    Converges Windows Remote Desktop (RDP) service state and firewall access.

  .DESCRIPTION
    Starts the Windows built-in RDP server (TermService) and
    the firewall rule permits inbound connections on TCP 3389, completing the
    three-protocol remote-desktop baseline alongside Chrome Remote Desktop and
    Parsec:
      - Service startup type: Automatic
      - Service state: Running
      - Firewall rule: RemoteDesktop-UserMode-In-TCP enabled
      - Firewall rule: RemoteDesktop-UserMode-In-UDP enabled

    The registry key fDenyTSConnections is managed declaratively via
    system/dsc.yml rather than here, so this function only controls service
    lifecycle and firewall state.

    When disabled, the function reverses managed state:
      - Stops TermService and sets startup type to Manual
      - Disables the RemoteDesktop-UserMode-In-TCP firewall rule
      - Disables the RemoteDesktop-UserMode-In-UDP firewall rule

  .PARAMETER Enabled
    Whether Windows built-in RDP parity should be enforced. Mandatory: caller
    must explicitly choose true (apply managed RDP state) or false (cleanup).

  .EXAMPLE
    Sync-WindowsRDP -Enabled:$true

  .EXAMPLE
    Sync-WindowsRDP -Enabled:$false

  .NOTES
    Environment variables:
      (none)    No environment variables used.

    Exit codes:
      0 on success; 1 on error.
  #>
  param(
    [Parameter(Mandatory)]
    [bool]$Enabled
  )

  # check-suppress:suppression_doc: probe whether RDP service is installed; Get-Service throws when absent.
  $rdpService = Get-Service -Name 'TermService' -ErrorAction SilentlyContinue
  if ($null -eq $rdpService) {
    Write-NucleusWarning -CommandName 'windows-rdp' "Remote Desktop service (TermService) not found; skipping RDP convergence."
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
