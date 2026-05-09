# modules/windows/sync-secretfile.ps1 — Per-file secret materialization.
#
# Decrypts one SOPS file and converges only managed SSH/GPG payloads for the
# configured primary user.  Also maintains managed-key manifest files in
# ~/.config/nucleus/ to enable rotation detection and agent flush on rotation,
# mirroring the POSIX gpgImport and sshKeyAdopt Home Manager activations.

function Sync-SecretFile {
  <#
  .SYNOPSIS
    Decrypts one SOPS secret file and materializes its payloads on disk.

  .DESCRIPTION
    Calls Get-Secrets to decrypt $FilePath, then processes five
    username-scoped flat keys:

    ssh_personal_${username}
      Written to $HOME\.ssh\ssh_personal_${username} using ASCII encoding
      (no BOM, no trailing newline). The file is only overwritten when content
      changes.

    ssh_personal_${username}_pub
      Written to $HOME\.ssh\ssh_personal_${username}.pub using ASCII encoding
      (no BOM, no trailing newline). The file is only overwritten when content
      changes.  The SHA-256 fingerprint is recorded in
      $HOME\.config\nucleus\managed-ssh-keys for rotation detection; the
      SSH agent is flushed (ssh-add -D) when the fingerprint changes.

    ssh_personal_${username}_rsa
      Written to $HOME\.ssh\ssh_personal_${username}_rsa using ASCII encoding
      (no BOM, no trailing newline). The file is only overwritten when content
      changes.

    ssh_personal_${username}_rsa_pub
      Written to $HOME\.ssh\ssh_personal_${username}_rsa.pub using ASCII
      encoding (no BOM, no trailing newline). The file is only overwritten when
      content changes.

    gpg_personal_${username}
      Imported into the current GPG keyring via stdin (`gpg --batch --import -`).
      No temporary plaintext files are created.  The managed primary fingerprint
      is recorded in $HOME\.config\nucleus\managed-gpg-keys immediately after a
      successful import so the key is tracked even if ownertrust enforcement
      fails transiently.

    git_identity_${username}
      Written to $HOME\.config\nucleus\git-identity.env so Git identity can be
      converged from SOPS-managed values instead of static mappings.

    $HOME\.ssh is created if it does not already exist.
    $HOME\.config\nucleus is created if it does not already exist.

  .PARAMETER FilePath
    Absolute path to the SOPS-encrypted YAML file.

  .PARAMETER GpgExe
    Absolute path to the gpg executable.

  .PARAMETER HostKeyPath
    Path to this machine's SSH host private key used as the age decryption key.

  .PARAMETER PrimarySshKeyPath
    Path to the primary user's managed SSH private key used as the final
    fallback age decryption identity.

  .PARAMETER SopsExe
    Absolute path to the sops executable.

  .PARAMETER PrimaryUsername
    Canonical primary username allowed to materialize/import secrets.

  .EXAMPLE
    Sync-SecretFile -FilePath '.\ssh-personal.yml' -GpgExe 'gpg.exe' `
      -HostKeyPath 'C:\ProgramData\ssh\ssh_host_ed25519_key' `
      -PrimarySshKeyPath "$HOME\.ssh\ssh_personal_polyipseity" -SopsExe 'sops.exe' `
      -PrimaryUsername 'polyipseity'
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
    [string]$SopsExe,

    [Parameter(Mandatory = $true)]
    [string]$PrimaryUsername
  )

  if (-not (Test-PrimaryUser -PrimaryUsername $PrimaryUsername -Quiet)) {
    return
  }

  $secretFileInfo = Get-Item -Path $FilePath
  $gpgSecretName = "gpg_personal_$PrimaryUsername"
  $gitIdentityConfigDir = Join-Path -Path $HOME -ChildPath ".config\nucleus"
  $gitIdentityPath = Join-Path -Path $gitIdentityConfigDir -ChildPath "git-identity.env"
  $gitIdentitySecretName = "git_identity_$PrimaryUsername"
  # Manifest files record managed key fingerprints for rotation detection,
  # mirroring the POSIX gpgImport and sshKeyAdopt Home Manager activations.
  $managedGpgKeysManifest = Join-Path -Path $gitIdentityConfigDir -ChildPath 'managed-gpg-keys'
  $managedSshKeysManifest = Join-Path -Path $gitIdentityConfigDir -ChildPath 'managed-ssh-keys'
  $sshDir = Join-Path -Path $HOME -ChildPath ".ssh"
  $sshPublicSecretName = "ssh_personal_${PrimaryUsername}_pub"
  $sshRsaPublicSecretName = "ssh_personal_${PrimaryUsername}_rsa_pub"
  $sshRsaSecretName = "ssh_personal_${PrimaryUsername}_rsa"
  $sshSecretName = "ssh_personal_$PrimaryUsername"

  if (-not (Test-Path -Path $sshDir)) {
    New-Item -ItemType Directory -Path $sshDir -Force | Out-Null
  }

  if (-not (Test-Path -Path $gitIdentityConfigDir)) {
    New-Item -ItemType Directory -Path $gitIdentityConfigDir -Force | Out-Null
  }

  # Script block that removes inherited ACEs and grants only the current user
  # FullControl on a file.  Removing inherited entries eliminates the default
  # Users/Everyone grants that make private key and config material world-readable.
  # Mirrors POSIX chmod 600.  Called unconditionally so the ACL is idempotent
  # across apply runs even when file content has not changed.
  $restrictAcl = {
    param([string]$Path)
    $currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    # /inheritance:r removes inherited ACEs; /grant:r replaces any existing rule.
    # Soft-failure: icacls may not be available on non-NTFS volumes or in some
    # sandboxed environments; warn and continue rather than aborting the apply.
    & icacls.exe $Path /inheritance:r /grant:r "${currentUser}:(F)" | Out-Null
    if ($LASTEXITCODE -ne 0) {
      Write-Warning "secrets: could not restrict ACL on $Path (icacls exit $LASTEXITCODE)"
    }
  }

  Write-Host "Processing secrets from: $($secretFileInfo.Name)" -ForegroundColor Cyan
  $jsonSecrets = Get-Secrets -FilePath $secretFileInfo.FullName -GpgExe $GpgExe -HostKeyPath $HostKeyPath -PrimarySshKeyPath $PrimarySshKeyPath -SopsExe $SopsExe

  if ($null -ne $jsonSecrets.PSObject.Properties[$sshSecretName]) {
    $sshKeyPath = Join-Path -Path $sshDir -ChildPath $sshSecretName
    $sshKeyValue = [string]$jsonSecrets.$sshSecretName
    $existingValue = if (Test-Path -Path $sshKeyPath) {
      Get-Content -Path $sshKeyPath -Raw
    }
    else {
      ""
    }

    if ($existingValue -ne $sshKeyValue) {
      $sshKeyValue | Out-File -FilePath $sshKeyPath -Encoding ascii -NoNewline
      Write-Host "  Updated SSH key: $sshSecretName" -ForegroundColor Cyan
    }
    # Restrict ACL unconditionally so idempotent re-applies re-lock the key even
    # when content is unchanged.  Mirrors POSIX chmod 600.
    & $restrictAcl -Path $sshKeyPath
  }

  if ($null -ne $jsonSecrets.PSObject.Properties[$sshPublicSecretName]) {
    $sshPublicKeyPath = Join-Path -Path $sshDir -ChildPath "${sshSecretName}.pub"
    $sshPublicKeyValue = [string]$jsonSecrets.$sshPublicSecretName
    $existingPublicValue = if (Test-Path -Path $sshPublicKeyPath) {
      Get-Content -Path $sshPublicKeyPath -Raw
    }
    else {
      ""
    }

    if ($existingPublicValue -ne $sshPublicKeyValue) {
      $sshPublicKeyValue | Out-File -FilePath $sshPublicKeyPath -Encoding ascii -NoNewline
      Write-Host "  Updated SSH public key: $sshPublicSecretName" -ForegroundColor Cyan
    }

    # Track the SHA-256 fingerprint of the SSH public key for rotation
    # detection and SSH agent flush on rotation.  Mirrors the POSIX
    # sshKeyAdopt Home Manager activation in secrets.nix.
    try {
      $sshKeyParts = $sshPublicKeyValue.Trim() -split '\s+'
      if ($sshKeyParts.Length -ge 2) {
        $sshKeyBytes = [System.Convert]::FromBase64String($sshKeyParts[1])
        $sha256Hasher = [System.Security.Cryptography.SHA256]::Create()
        $hashBytes = $sha256Hasher.ComputeHash($sshKeyBytes)
        $newSshFingerprint = 'SHA256:' + [System.Convert]::ToBase64String($hashBytes).TrimEnd('=')

        $oldSshFingerprint = if (Test-Path -Path $managedSshKeysManifest) {
          (Get-Content -Path $managedSshKeysManifest -Raw).Trim()
        }
        else {
          ''
        }

        if ($oldSshFingerprint -ne $newSshFingerprint) {
          # Flush SSH agent when fingerprint changes, including on first provision
          # (absent manifest → empty $oldSshFingerprint differs from new key).
          # This evicts any pre-placed key already loaded in the agent before
          # the managed key was materialized.  Soft-failure so apply proceeds
          # even when no agent is running.  Parity with POSIX sshKeyAdopt behavior.
          $sshAddCommand = Get-Command 'ssh-add' -ErrorAction SilentlyContinue
          if ($null -ne $sshAddCommand) {
            # 2>$null is intentional: ssh-add -D emits "Could not connect to
            # your authentication agent" when no agent is running.  That
            # failure is benign — nothing to flush — and the noise would
            # obscure the meaningful rotation log line below.
            & $sshAddCommand.Source -D 2>$null | Out-Null
            Write-Host "  Flushed SSH agent due to key rotation ($oldSshFingerprint -> $newSshFingerprint)" -ForegroundColor Cyan
          }
        }

        $newSshFingerprint | Out-File -FilePath $managedSshKeysManifest -Encoding ascii -NoNewline
        # Restrict ACL unconditionally; manifest contains key fingerprints that
        # should not be world-readable.  Mirrors POSIX chmod 600.
        & $restrictAcl -Path $managedSshKeysManifest
      }
    }
    catch {
      Write-Warning "secrets: could not update SSH fingerprint manifest: $_"
    }
  }

  if ($null -ne $jsonSecrets.PSObject.Properties[$sshRsaSecretName]) {
    $sshRsaKeyPath = Join-Path -Path $sshDir -ChildPath $sshRsaSecretName
    $sshRsaKeyValue = [string]$jsonSecrets.$sshRsaSecretName
    $existingRsaValue = if (Test-Path -Path $sshRsaKeyPath) {
      Get-Content -Path $sshRsaKeyPath -Raw
    }
    else {
      ""
    }

    if ($existingRsaValue -ne $sshRsaKeyValue) {
      $sshRsaKeyValue | Out-File -FilePath $sshRsaKeyPath -Encoding ascii -NoNewline
      Write-Host "  Updated SSH key: $sshRsaSecretName" -ForegroundColor Cyan
    }
    # Restrict ACL unconditionally.  Mirrors POSIX chmod 600.
    & $restrictAcl -Path $sshRsaKeyPath
  }

  if ($null -ne $jsonSecrets.PSObject.Properties[$sshRsaPublicSecretName]) {
    $sshRsaPublicKeyPath = Join-Path -Path $sshDir -ChildPath "${sshRsaSecretName}.pub"
    $sshRsaPublicKeyValue = [string]$jsonSecrets.$sshRsaPublicSecretName
    $existingRsaPublicValue = if (Test-Path -Path $sshRsaPublicKeyPath) {
      Get-Content -Path $sshRsaPublicKeyPath -Raw
    }
    else {
      ""
    }

    if ($existingRsaPublicValue -ne $sshRsaPublicKeyValue) {
      $sshRsaPublicKeyValue | Out-File -FilePath $sshRsaPublicKeyPath -Encoding ascii -NoNewline
      Write-Host "  Updated SSH public key: $sshRsaPublicSecretName" -ForegroundColor Cyan
    }
  }

  if ($null -ne $jsonSecrets.PSObject.Properties[$gpgSecretName]) {
    $gpgKeyValue = [string]$jsonSecrets.$gpgSecretName
    if (-not [string]::IsNullOrWhiteSpace($gpgKeyValue)) {
      $firstFingerprint = $null
      $showOnlyOutput = $gpgKeyValue | & $GpgExe --batch --import-options show-only --dry-run --with-colons --import -
      foreach ($line in $showOnlyOutput) {
        if ($line -like "fpr:*") {
          $parts = $line -split ":"
          if ($parts.Length -ge 10 -and -not [string]::IsNullOrWhiteSpace($parts[9])) {
            $firstFingerprint = $parts[9]
            break
          }
        }
      }

      $gpgKeyValue | & $GpgExe --batch --import - | Out-Null
      if ($LASTEXITCODE -ne 0) {
        throw "Failed to import GPG material '$gpgSecretName'. Exit code: $LASTEXITCODE"
      }

      if ([string]::IsNullOrWhiteSpace($firstFingerprint)) {
        throw "Imported GPG key material but no managed primary fingerprint was detected for ownertrust enforcement."
      }

      # Write the manifest before ownertrust so the key is tracked even if
      # ownertrust enforcement fails transiently (e.g. GnuPG 2.5 + Kyber IPC
      # edge cases on first bootstrap).  Mirrors the POSIX gpgImport order in
      # secrets.nix.
      $firstFingerprint | Out-File -FilePath $managedGpgKeysManifest -Encoding ascii -NoNewline
      # Restrict ACL unconditionally; manifest contains the managed GPG
      # fingerprint and must not be world-readable.  Mirrors POSIX chmod 600.
      & $restrictAcl -Path $managedGpgKeysManifest

      # Ownertrust is best-effort: demote failure to a warning so a transient
      # GnuPG IPC error doesn't abort the whole apply run.  The key is already
      # in the keyring and tracked in the manifest at this point.
      "${firstFingerprint}:6:" | & $GpgExe --import-ownertrust | Out-Null
      if ($LASTEXITCODE -ne 0) {
        Write-Warning "secrets: ownertrust enforcement for '$firstFingerprint' exited $LASTEXITCODE — key imported and manifest updated, ownertrust may need a retry"
      }

      Write-Host "  Imported GPG material: $gpgSecretName" -ForegroundColor Cyan
    }
  }

  if ($null -ne $jsonSecrets.PSObject.Properties[$gitIdentitySecretName]) {
    $gitIdentityValue = [string]$jsonSecrets.$gitIdentitySecretName
    $existingIdentityValue = if (Test-Path -Path $gitIdentityPath) {
      Get-Content -Path $gitIdentityPath -Raw
    }
    else {
      ""
    }

    if ($existingIdentityValue -ne $gitIdentityValue) {
      $gitIdentityValue | Out-File -FilePath $gitIdentityPath -Encoding ascii -NoNewline
      Write-Host "  Updated Git identity payload: $gitIdentitySecretName" -ForegroundColor Cyan
    }
    # Restrict ACL unconditionally; git-identity.env contains name/email and
    # should not be world-readable.  Mirrors POSIX chmod 600.
    & $restrictAcl -Path $gitIdentityPath
  }
}
