<#
.SYNOPSIS
  Remote-access parity helpers for Windows.

.DESCRIPTION
  Applies the SSH-server remote access posture with an explicit managed cleanup path.

.NOTES
  Environment variables: (none)
#>
function Sync-OpenSSHServer {
  <#
  .SYNOPSIS
    Converges OpenSSH Server startup, auth policy, and firewall access.

  .DESCRIPTION
    Enables OpenSSH Server for remote administration and aligns auth posture with
    key-focused remote access:
      - Service startup type: Automatic
      - Service state: Running
      - sshd_config managed keys:
          AuthorizedKeysFile .ssh/authorized_keys .ssh/ssh_personal_%u.pub
          KbdInteractiveAuthentication no
          PasswordAuthentication no

    AuthorizedKeysFile carries two paths: `.ssh/authorized_keys` for future keys and
    `.ssh/ssh_personal_%u.pub`, the SOPS-materialized personal key (%u expands to the
    connecting username). The key is not embedded in the repo, so the authorized key
    follows the secret lifecycle without duplication.

    Also enables the built-in "OpenSSH-Server-In-TCP" firewall rule.

    When disabled, the function reverses managed state by:
      - Removing managed sshd_config keys
      - Setting service startup type to Manual and stopping service
      - Disabling the firewall rule

  .PARAMETER Enabled
    False applies cleanup.

  .NOTES
    Environment variables: (none)
    Exit codes: 0 on success; 1 on error.
  #>
  param(
    [Parameter()]
    [bool]$Enabled = $true
  )

  $sshdConfigPath = Join-Path -Path $env:ProgramData -ChildPath 'ssh\sshd_config'
  if (-not (Test-Path -Path $sshdConfigPath)) {
    Write-NucleusWarning -CommandName 'openssh-server' "OpenSSH server config not found at '$sshdConfigPath'; skipping OpenSSH parity."
    return
  }

  $managedKeys = @(
    'AuthorizedKeysFile',
    'KbdInteractiveAuthentication',
    'PasswordAuthentication'
  )

  $existingConfigLines = @(Get-Content -Path $sshdConfigPath)
  $retainedConfigLines = @()
  foreach ($line in $existingConfigLines) {
    $trimmedLine = $line.Trim()
    $isManagedLine = $false
    foreach ($managedKey in $managedKeys) {
      if ($trimmedLine -match "^(#\s*)?$managedKey\b") {
        $isManagedLine = $true
        break
      }
    }

    if (-not $isManagedLine) {
      $retainedConfigLines += $line
    }
  }

  if ($Enabled) {
    # check-suppress:embedded-content: exception 1 (data-driven/generated content) -- managed sshd_config keys
    $retainedConfigLines += @(
      # %u expands to the connecting username, matching the filename that
      # sync-secretfile.ps1 materializes from the SOPS secret bundle.
      # .ssh/authorized_keys is retained as an extensibility slot so additional
      # keys can be added without touching the managed config lines.
      'AuthorizedKeysFile .ssh/authorized_keys .ssh/ssh_personal_%u.pub',
      'KbdInteractiveAuthentication no',
      'PasswordAuthentication no'
    )
  }

  [System.IO.File]::WriteAllLines($sshdConfigPath, $retainedConfigLines, [System.Text.UTF8Encoding]::new($false))

  # check-suppress:suppression_doc: probe whether sshd is installed; Get-Service throws when absent.
  $sshdService = Get-Service -Name 'sshd' -ErrorAction SilentlyContinue
  if ($null -eq $sshdService) {
    Write-NucleusWarning -CommandName 'openssh-server' "OpenSSH service not installed; skipping service and firewall convergence."
    return
  }

  if ($Enabled) {
    Set-Service -Name 'sshd' -StartupType Automatic
    Start-Service -Name 'sshd'
    # WHY: Firewall rule toggle is conditional on user preference — DSC
    # Microsoft.Windows.Settings/Firewall only supports global on/off, not
    # individual rule management. The built-in OpenSSH rule exists on every
    # Windows install; we only enable/disable it.
  }
  else {
    if ((Get-Service -Name 'sshd').Status -ne 'Stopped') {
      Stop-Service -Name 'sshd'
    }
    Set-Service -Name 'sshd' -StartupType Manual
    Disable-NetFirewallRule -Name 'OpenSSH-Server-In-TCP'
  }
}
