# modules/windows/get-decryptedblob.ps1 — Binary blob decryption helper.
#
# Decrypts SOPS binary payloads with the same key precedence chain used for
# structured secrets and writes plaintext directly to disk.

function Get-DecryptedBlob {
  <#
  .SYNOPSIS
    Decrypts a SOPS-encrypted binary blob and writes the plaintext to
    $OutputPath.

  .DESCRIPTION
    Similar key-priority logic to Get-Secrets (machine SSH key, then GPG,
    then primary SSH key), but uses `sops --output` to write the raw decrypted
    bytes directly to $OutputPath instead of capturing stdout.  Used for binary
    assets such as wallpaper images that cannot be embedded in JSON.

  .PARAMETER FilePath
    Absolute path to the SOPS-encrypted blob file (typically *.sops).

  .PARAMETER GpgExe
    Absolute path to the gpg executable.

  .PARAMETER HostKeyPath
    Path to this machine's SSH host private key backing the age recipient.

  .PARAMETER PrimarySshKeyPath
    Path to the primary user's managed SSH private key used as the final
    fallback age decryption identity.

  .PARAMETER OutputPath
    Destination path where the decrypted bytes will be written.

  .PARAMETER SopsExe
    Absolute path to the sops executable.

  .EXAMPLE
    Get-DecryptedBlob -FilePath '.\wallpaper.jpg.sops' -GpgExe 'gpg.exe' `
    -HostKeyPath 'C:\ProgramData\ssh\ssh_host_ed25519_key' `
    -PrimarySshKeyPath "C:\Users\admin\.ssh\ssh_personal_admin" `
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
    [string]$PrimarySshKeyPath,

    [Parameter(Mandatory = $true)]
    [string]$OutputPath,

    [Parameter(Mandatory = $true)]
    [string]$SopsExe
  )

  $sopsArgs = @("--decrypt", "--output", $OutputPath, $FilePath)

  if (Test-Path -Path $HostKeyPath) {
    $env:SOPS_AGE_SSH_PRIVATE_KEY_FILE = $HostKeyPath

    try {
      & $SopsExe @sopsArgs
      if ($LASTEXITCODE -eq 0) {
        return
      }

      Write-Output "Machine-key decryption failed for '$FilePath'. Falling back to GPG keyring..."
    }
    finally {
      # SilentlyContinue in a finally block prevents a cleanup failure from
      # masking the original exception from the try block above.
      Remove-Item Env:SOPS_AGE_SSH_PRIVATE_KEY_FILE -ErrorAction SilentlyContinue
    }
  }

  $secretKeyInfo = & $GpgExe --list-secret-keys --with-colons
  $hasGpgSecretKeys = ($secretKeyInfo -and ($secretKeyInfo -match "^(sec|ssb):"))
  if ($hasGpgSecretKeys) {
    & $SopsExe @sopsArgs
    if ($LASTEXITCODE -eq 0) {
      return
    }

    Write-Output "GPG decryption failed for '$FilePath'. Trying primary SSH key fallback..."
  }
  else {
    Write-Output "No GPG secret keys detected. Trying primary SSH key fallback for '$FilePath'..."
  }

  if (Test-Path -Path $PrimarySshKeyPath) {
    Write-Output "Found primary SSH key. Trying primary-ssh decryption for '$FilePath'..."
    $env:SOPS_AGE_SSH_PRIVATE_KEY_FILE = $PrimarySshKeyPath

    try {
      & $SopsExe @sopsArgs
      if ($LASTEXITCODE -eq 0) {
        return
      }

      throw "Primary-ssh decryption failed for '$FilePath' after machine-key and GPG attempts."
    }
    finally {
      # SilentlyContinue in a finally block prevents a cleanup failure from
      # masking the original exception from the try block above.
      Remove-Item Env:SOPS_AGE_SSH_PRIVATE_KEY_FILE -ErrorAction SilentlyContinue
    }
  }

  throw "Failed to decrypt blob '$FilePath'. Machine SSH key, GPG keyring, and primary SSH key were unavailable or failed."
}
