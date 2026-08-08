function Get-DecryptedBlob {
  <#
  .SYNOPSIS
    Decrypts a SOPS-encrypted binary blob and writes the plaintext to
    $OutputPath.

  .DESCRIPTION
    Uses the same machine-ssh -> machine-age -> user-ssh -> gpg fallback chain as
    Get-Secret, but writes raw decrypted bytes to a file via `sops --output`.
    Used for binary assets such as wallpaper images.

  .PARAMETER FilePath
    Absolute path to the SOPS-encrypted blob file (typically *.sops).

  .PARAMETER GpgExe
    Absolute path to the gpg executable.

  .PARAMETER HostKeyPath
    Path to this machine's SSH host private key backing the age recipient.

  .PARAMETER RepoRoot
    Absolute path to the nucleus repository root (enumerates src/secrets/users).

  .PARAMETER PrimarySshKeyPath
    Optional transition fallback: path to a managed SSH private key tried after
    user manifests and before the GPG keyring.

  .PARAMETER OutputPath
    Destination path where the decrypted bytes will be written.

  .PARAMETER SopsExe
    Absolute path to the sops executable.

  .EXAMPLE
    Get-DecryptedBlob -FilePath '.\wallpaper.jpg.sops' -GpgExe 'gpg.exe' `
      -HostKeyPath 'C:\ProgramData\ssh\ssh_host_ed25519_key' `
      -RepoRoot 'C:\Users\admin\nucleus' `
      -OutputPath 'C:\Users\admin\Pictures\wallpaper.jpg' -SopsExe 'sops.exe'
  #>
  param(
    [Parameter(Mandatory = $true)]
    [string]$FilePath,

    [Parameter(Mandatory = $true)]
    [string]$GpgExe,

    [Parameter(Mandatory = $true)]
    [string]$HostKeyPath,

    [Parameter(Mandatory = $true)]
    [string]$RepoRoot,

    [Parameter(Mandatory = $true)]
    [string]$OutputPath,

    [Parameter(Mandatory = $true)]
    [string]$SopsExe,

    [string]$PrimarySshKeyPath
  )

  $sopsArgs = @('--decrypt', '--output', $OutputPath, $FilePath)
  $decryptedOutput = Invoke-SopsDecrypt `
    -SopsExe $SopsExe `
    -SopsArgs $sopsArgs `
    -GpgExe $GpgExe `
    -HostKeyPath $HostKeyPath `
    -RepoRoot $RepoRoot `
    -PrimarySshKeyPath $PrimarySshKeyPath

  if ($null -eq $decryptedOutput) {
    throw "Failed to decrypt blob '$FilePath'. Machine SSH key, machine age key, user SSH keys, and GPG keyring were unavailable or failed."
  }
}
