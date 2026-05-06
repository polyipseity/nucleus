# modules/windows/remove-nucleusmanagedsecrets.ps1 — Managed secret cleanup helper.
#
# Removes only repository-managed SSH key material, Git identity payload, and
# key-manifest files so disable paths stay idempotent and scoped.

function Remove-NucleusManagedSecrets {
  <#
  .SYNOPSIS
    Removes managed SSH key material and key manifests for the primary user.

  .DESCRIPTION
    Cleanup companion for secret parity toggles. Removes only files managed by
    this repository (`ssh_personal_<user>`, `ssh_personal_<user>_rsa`,
    corresponding `.pub` files, `~/.config/nucleus/git-identity.env`, and the
    key-rotation manifest files `~/.config/nucleus/managed-gpg-keys` and
    `~/.config/nucleus/managed-ssh-keys`).

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
  $nucleusConfigDir = Join-Path -Path $HOME -ChildPath '.config\nucleus'

  foreach ($managedPath in @(
      (Join-Path -Path $sshDir -ChildPath $sshSecretName),
      (Join-Path -Path $sshDir -ChildPath "${sshSecretName}.pub"),
      (Join-Path -Path $sshDir -ChildPath $sshRsaSecretName),
      (Join-Path -Path $sshDir -ChildPath "${sshRsaSecretName}.pub"),
      (Join-Path -Path $HOME -ChildPath ".config\nucleus\git-identity.env"),
      # Remove key-rotation manifest files so a future re-enable starts with a
      # clean baseline and does not spuriously detect a rotation on first sync.
      (Join-Path -Path $nucleusConfigDir -ChildPath 'managed-gpg-keys'),
      (Join-Path -Path $nucleusConfigDir -ChildPath 'managed-ssh-keys')
    )) {
    if (Test-Path -Path $managedPath) {
      Remove-Item -Path $managedPath -Force
    }
  }
}
