# modules/windows/remote-access.ps1 — Remote-access parity helpers for Windows.
#
# Applies SSH-server remote access posture with explicit managed cleanup path.

function Sync-NucleusOpenSshServer {
  <#
  .SYNOPSIS
    Converges OpenSSH Server startup, auth policy, and firewall access.

  .DESCRIPTION
    Ensures OpenSSH Server is enabled for remote administration and aligns auth
    posture with key-focused remote access:
      - Service startup type: Automatic
      - Service state: Running
      - sshd_config managed keys:
          PasswordAuthentication no
          KbdInteractiveAuthentication no

    Also ensures the built-in "OpenSSH-Server-In-TCP" firewall rule is enabled.

    When disabled, the function reverses managed state by:
      - Removing managed sshd_config keys
      - Setting service startup type to Manual and stopping service
      - Disabling the firewall rule

  .PARAMETER Enabled
    Whether remote-access parity should be enforced. False applies cleanup.

  .EXAMPLE
    Sync-NucleusOpenSshServer -Enabled:$true

  .EXAMPLE
    Sync-NucleusOpenSshServer -Enabled:$false
  #>
  param(
    [Parameter()]
    [bool]$Enabled = $true
  )

  $sshdConfigPath = Join-Path -Path $env:ProgramData -ChildPath 'ssh\sshd_config'
  if (-not (Test-Path -Path $sshdConfigPath)) {
    Write-Host "OpenSSH server config not found at '$sshdConfigPath'; skipping OpenSSH parity." -ForegroundColor Yellow
    return
  }

  $managedKeys = @(
    'PasswordAuthentication',
    'KbdInteractiveAuthentication'
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
      'KbdInteractiveAuthentication no',
      'PasswordAuthentication no'
    )
  }

  [System.IO.File]::WriteAllLines($sshdConfigPath, $retainedConfigLines, [System.Text.UTF8Encoding]::new($false))

  $sshdService = Get-Service -Name 'sshd' -ErrorAction SilentlyContinue
  if ($null -eq $sshdService) {
    Write-Host 'OpenSSH service not installed; skipping service and firewall convergence.' -ForegroundColor Yellow
    return
  }

  if ($Enabled) {
    Set-Service -Name 'sshd' -StartupType Automatic
    Start-Service -Name 'sshd' -ErrorAction SilentlyContinue
    Enable-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue
  }
  else {
    Stop-Service -Name 'sshd' -ErrorAction SilentlyContinue
    Set-Service -Name 'sshd' -StartupType Manual
    Disable-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue
  }
}
