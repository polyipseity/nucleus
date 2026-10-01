<#
.SYNOPSIS
  SSH host key bootstrap helper.

.DESCRIPTION
  Windows twin of generate_ssh_host_key_if_needed in src/scripts/apply.sh. The
  host key is absent on a fresh machine until the OpenSSH Server service first
  starts, so this starts it briefly to trigger generation when the service is
  installed but the key file is not.

.NOTES
  Environment variables:
    ProgramData  Path to the ProgramData directory (default: C:\ProgramData).
#>
function Initialize-SSHHostKey {
  <#
  .SYNOPSIS
    Verify the Windows SSH host Ed25519 key exists, generating it if absent.

  .DESCRIPTION
    Returns immediately when the key exists (idempotent). Otherwise starts sshd
    briefly to make Windows OpenSSH generate the key, waits up to
    StartupTimeoutSeconds, then restores the original running state.

    A missing sshd warns and returns without error; Register-HostAgeKey
    completes registration on a later apply.
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

  # check-suppress:suppression_doc: probe whether sshd is installed; Get-Service throws when absent.
  $sshdService = Get-Service -Name 'sshd' -ErrorAction SilentlyContinue
  if ($null -eq $sshdService) {
    # sshd absent on a fresh machine without the OpenSSH Server feature: warn.
    # Sync-OpenSSHServer and the trailing Register-HostAgeKey call finish the
    # job on a later apply.
    Write-NucleusWarning -CommandName 'SSH' ("sshd service not installed; SSH host key cannot be " +
                   "generated yet.  Keys will be generated when sshd is available " +
                   "(enable the OpenSSH Server Windows optional feature).")
    return
  }

  # Start the service briefly so Windows OpenSSH generates the host key files,
  # then restore the prior state. Startup and firewall convergence belongs to
  # Sync-NucleusOpenSshServer, called later in the apply run.
  $wasRunning = $sshdService.Status -eq 'Running'
  if (-not $wasRunning) {
    Write-NucleusInfo -CommandName 'SSH' "starting sshd temporarily to generate SSH host keys..."
    Start-Service -Name 'sshd'
  }

  # Windows OpenSSH writes the key on first start, but polling keeps the
  # filesystem view consistent for the steps that read it next.
  $elapsed = 0
  while (-not (Test-Path -Path $MachineSshHostKeyPath) -and $elapsed -lt $StartupTimeoutSeconds) {
    Start-Sleep -Seconds 1
    $elapsed++
  }

  if (-not $wasRunning) {
    # Do not leave sshd running; Sync-OpenSSHServer owns enablement.
    Stop-Service -Name 'sshd' -Force
  }

  if (-not (Test-Path -Path $MachineSshHostKeyPath)) {
    # Advisory warning: a second apply run will succeed once the keys are fully
    # written to disk (for example if sshd initialisation takes longer than
    # StartupTimeoutSeconds on this hardware).
    Write-NucleusWarning -CommandName 'SSH' ("sshd started but $MachineSshHostKeyPath still absent after " +
                   "${StartupTimeoutSeconds}s.  Run apply again after sshd fully initializes.")
  }
  else {
    Write-NucleusInfo -CommandName 'SSH' "SSH host keys generated."
  }
}
