# modules/windows/initialize-sshhostkey.ps1 — SSH host key bootstrap helper.
#
# Mirrors generate_ssh_host_key_if_needed in src/scripts/apply.sh.
# Ensures the Windows SSH host Ed25519 key exists before
# register-hostagekey.ps1 tries to derive the machine age public key from
# the corresponding .pub file.  On a fresh machine the key is absent until the
# OpenSSH Server Windows service first starts; this module starts the service
# briefly to trigger automatic key generation when the service is already
# installed but the key file has not yet been written.

function Initialize-SSHHostKey {
  <#
  .SYNOPSIS
    Ensures the Windows SSH host Ed25519 key exists, generating it if absent.

  .DESCRIPTION
    Checks whether the SSH host Ed25519 private key exists and returns
    immediately if it does (idempotent; safe to call on every apply run).

    If the key is absent and the Windows sshd service is already installed
    (for example from a prior apply that installed OpenSSH via WinGet DSC),
    starts the service briefly to trigger automatic host key generation by
    Windows OpenSSH, waits up to StartupTimeoutSeconds for the key to appear,
    then restores the service to its original running state.

    If sshd is not yet installed (first-ever apply on a fresh machine before
    WinGet DSC has run), emits an advisory warning and returns without error.
    After DSC installs OpenSSH and Sync-NucleusOpenSshServer starts the service,
    the keys will be generated in the same apply run and the trailing call to
    Register-HostAgeKey will complete registration automatically.

  .PARAMETER MachineSshHostKeyPath
    Path to the SSH host Ed25519 private key file.
    Defaults to C:\ProgramData\ssh\ssh_host_ed25519_key.

  .PARAMETER StartupTimeoutSeconds
    Maximum seconds to wait for sshd to generate host keys after the service
    is started.  Defaults to 10.

  .EXAMPLE
    Initialize-SSHHostKey

  .EXAMPLE
    Initialize-SSHHostKey -MachineSshHostKeyPath 'C:\ProgramData\ssh\ssh_host_ed25519_key'
  #>
  [CmdletBinding()]
  param(
    [Parameter()]
    [string]$MachineSshHostKeyPath = (Join-Path -Path $env:ProgramData -ChildPath "ssh\ssh_host_ed25519_key"),

    [Parameter()]
    [int]$StartupTimeoutSeconds = 10
  )

  if (Test-Path -Path $MachineSshHostKeyPath) {
    # Key already present; nothing to do.
    return
  }

  $sshdService = Get-Service -Name 'sshd' -ErrorAction SilentlyContinue
  if ($null -eq $sshdService) {
    # sshd not yet installed: advisory warning only.  WinGet DSC
    # (system.dsc.yml) installs OpenSSH Server later in this apply run.
    # Sync-NucleusOpenSshServer then starts the service and host keys are
    # generated; the trailing Register-NucleusHostAgeKey call completes
    # registration in the same run.
    Write-Warning ("ssh: sshd service not installed; SSH host key cannot be " +
                   "generated yet.  Keys will be generated when Sync-NucleusOpenSshServer " +
                   "starts sshd after DSC installs OpenSSH.")
    return
  }

  # Service is installed but key absent: start it briefly so Windows OpenSSH
  # generates host key files automatically, then restore the prior state.
  # Convergence responsibility (Automatic startup, firewall rule) belongs to
  # Sync-NucleusOpenSshServer, called later in the apply run.
  $wasRunning = $sshdService.Status -eq 'Running'
  if (-not $wasRunning) {
    Write-Host "ssh: starting sshd temporarily to generate SSH host keys..." -ForegroundColor Cyan
    Start-Service -Name 'sshd'
  }

  # Poll for key creation.  Windows OpenSSH generates host keys synchronously
  # on first service start, but a brief polling interval ensures the filesystem
  # view is consistent before the key is read by subsequent steps.
  $elapsed = 0
  while (-not (Test-Path -Path $MachineSshHostKeyPath) -and $elapsed -lt $StartupTimeoutSeconds) {
    Start-Sleep -Seconds 1
    $elapsed++
  }

  if (-not $wasRunning) {
    # Restore the service to stopped so this function does not leave sshd
    # running unexpectedly; proper enablement is handled by Sync-NucleusOpenSshServer.
    Stop-Service -Name 'sshd' -Force
  }

  if (-not (Test-Path -Path $MachineSshHostKeyPath)) {
    # Advisory warning: a second apply run will succeed once the keys are fully
    # written to disk (for example if sshd initialisation takes longer than
    # StartupTimeoutSeconds on this hardware).
    Write-Warning ("ssh: sshd started but $MachineSshHostKeyPath still absent after " +
                   "${StartupTimeoutSeconds}s.  Run apply again after sshd fully initializes.")
  }
  else {
    Write-Host "ssh: SSH host keys generated." -ForegroundColor Green
  }
}
