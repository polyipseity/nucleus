# modules/windows/remote-access.ps1 — Remote-access parity helpers for Windows.
#
# Applies SSH-server remote access posture with explicit managed cleanup path.

function Sync-OpenSshServer {
  <#
  .SYNOPSIS
    Converges OpenSSH Server startup, auth policy, and firewall access.

  .DESCRIPTION
    Ensures OpenSSH Server is enabled for remote administration and aligns auth
    posture with key-focused remote access:
      - Service startup type: Automatic
      - Service state: Running
      - sshd_config managed keys:
          AuthorizedKeysFile .ssh/authorized_keys .ssh/ssh_personal_%u.pub
          KbdInteractiveAuthentication no
          PasswordAuthentication no

    AuthorizedKeysFile is set to two paths: `.ssh/authorized_keys` (standard
    extensibility path for future keys) and `.ssh/ssh_personal_%u.pub` (the
    SOPS-materialized personal public key, where %u expands to the connecting
    username at auth time).  The key is not embedded in the repository; sshd is
    pointed at the materialized path so the authorized key follows the secret
    management lifecycle without duplication.

    Also ensures the built-in "OpenSSH-Server-In-TCP" firewall rule is enabled.

    When disabled, the function reverses managed state by:
      - Removing managed sshd_config keys
      - Setting service startup type to Manual and stopping service
      - Disabling the firewall rule

  .PARAMETER Enabled
    Whether remote-access parity should be enforced. False applies cleanup.

  .EXAMPLE
    Sync-OpenSshServer -Enabled:$true

  .EXAMPLE
    Sync-OpenSshServer -Enabled:$false
  #>
  param(
    [Parameter()]
    [bool]$Enabled = $true
  )

  $sshdConfigPath = Join-Path -Path $env:ProgramData -ChildPath 'ssh\sshd_config'
  if (-not (Test-Path -Path $sshdConfigPath)) {
    Write-Output "$($PSStyle.Formatting.Warning)OpenSSH server config not found at '$sshdConfigPath'; skipping OpenSSH parity.$($PSStyle.Reset)"
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

  $sshdService = Get-Service -Name 'sshd' -ErrorAction SilentlyContinue
  if ($null -eq $sshdService) {
    Write-Output "$($PSStyle.Formatting.Warning)OpenSSH service not installed; skipping service and firewall convergence.$($PSStyle.Reset)"
    return
  }

  if ($Enabled) {
    Set-Service -Name 'sshd' -StartupType Automatic
    Start-Service -Name 'sshd'
    Enable-NetFirewallRule -Name 'OpenSSH-Server-In-TCP'
  }
  else {
    if ((Get-Service -Name 'sshd').Status -ne 'Stopped') {
      Stop-Service -Name 'sshd'
    }
    Set-Service -Name 'sshd' -StartupType Manual
    Disable-NetFirewallRule -Name 'OpenSSH-Server-In-TCP'
  }
}
