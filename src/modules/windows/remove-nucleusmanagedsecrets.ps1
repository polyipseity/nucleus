# modules/windows/remove-nucleusmanagedsecrets.ps1 — Managed secret cleanup helper.
#
# Removes only repository-managed SSH key material and Git identity payload so
# disable paths stay idempotent and scoped.

function Remove-NucleusManagedSecrets {
  <#
  .SYNOPSIS
    Removes managed SSH key material for the primary user.

  .DESCRIPTION
    Cleanup companion for secret parity toggles. Removes only files managed by
    this repository (`ssh_personal_<user>`, `ssh_personal_<user>_rsa`,
    corresponding `.pub` files, and `~/.config/nucleus/git-identity.env`).

    GPG keyring cleanup is intentionally out of scope because selective private
    key deletion is not reliably reversible without a canonical key inventory.

  .PARAMETER PrimaryUsername
    Canonical primary username allowed to receive managed secret cleanup.

  .EXAMPLE
    Remove-NucleusManagedSecrets -PrimaryUsername 'polyipseity'
  #>
  param(
    [Parameter(Mandatory = $true)]
    [string]$PrimaryUsername
  )

  if (-not (Test-NucleusPrimaryUser -PrimaryUsername $PrimaryUsername)) {
    return
  }

  $sshDir = Join-Path -Path $HOME -ChildPath '.ssh'
  $sshSecretName = "ssh_personal_$PrimaryUsername"
  $sshRsaSecretName = "${sshSecretName}_rsa"

  foreach ($managedPath in @(
      (Join-Path -Path $sshDir -ChildPath $sshSecretName),
      (Join-Path -Path $sshDir -ChildPath "${sshSecretName}.pub"),
      (Join-Path -Path $sshDir -ChildPath $sshRsaSecretName),
      (Join-Path -Path $sshDir -ChildPath "${sshRsaSecretName}.pub"),
      (Join-Path -Path $HOME -ChildPath ".config\nucleus\git-identity.env")
    )) {
    if (Test-Path -Path $managedPath) {
      Remove-Item -Path $managedPath -Force -ErrorAction SilentlyContinue
    }
  }
}
