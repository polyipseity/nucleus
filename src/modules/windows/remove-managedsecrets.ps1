# modules/windows/remove-managedsecrets.ps1 — Managed secret cleanup helper.
#
# Removes only repository-managed SSH key material, Git identity payload, and
# key-manifest files so disable paths stay idempotent and scoped.

function Remove-ManagedSecrets {
  <#
  .SYNOPSIS
    Removes managed SSH key material and key manifests for each specified user.

  .DESCRIPTION
    Cleanup companion for secret parity toggles. Iterates over each user in the
    `$Users` list and removes only repository-managed files in that user's home
    directory (`ssh_personal_<user>`, `ssh_personal_<user>_rsa`, corresponding
    `.pub` files, `~/.config/nucleus/git-identity.env`, and the key-rotation
    manifest files `~/.config/nucleus/managed-gpg-keys` and
    `~/.config/nucleus/managed-ssh-keys`).

    GPG keyring cleanup is intentionally out of scope because selective private
    key deletion is not reliably reversible without a canonical key inventory.

  .PARAMETER Users
    List of usernames whose managed secrets should be removed.

  .EXAMPLE
    Remove-NucleusManagedSecrets -Users @('polyipseity', 'someone')
  #>
  [CmdletBinding(SupportsShouldProcess = $true)]
  param(
    [Parameter(Mandatory = $true)]
    [string[]]$Users
  )

  foreach ($Username in $Users) {
    $userHome = [Environment]::GetFolderPath('SpecialFolder', $Username)
    $sshDir = Join-Path -Path $userHome -ChildPath '.ssh'
    $sshSecretName = "ssh_personal_$Username"
    $sshRsaSecretName = "${sshSecretName}_rsa"
    $configDir = Join-Path -Path $userHome -ChildPath '.config\nucleus'

    foreach ($managedPath in @(
        (Join-Path -Path $sshDir -ChildPath $sshSecretName),
        (Join-Path -Path $sshDir -ChildPath "${sshSecretName}.pub"),
        (Join-Path -Path $sshDir -ChildPath $sshRsaSecretName),
        (Join-Path -Path $sshDir -ChildPath "${sshRsaSecretName}.pub"),
        (Join-Path -Path $userHome -ChildPath ".config\nucleus\git-identity.env"),
        (Join-Path -Path $configDir -ChildPath 'managed-gpg-keys'),
        (Join-Path -Path $configDir -ChildPath 'managed-ssh-keys')
      )) {
      if (Test-Path -Path $managedPath) {
        if ($PSCmdlet.ShouldProcess($managedPath, 'Remove')) {
          Remove-Item -Path $managedPath -Force
        }
      }
    }
  }
}
