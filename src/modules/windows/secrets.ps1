# modules/windows/secrets.ps1 — JIT secret materialization helpers for Windows.
#
# Functions in this module decrypt SOPS-managed secret files and materialize
# primary-user SSH/GPG content on demand. Keep reusable secret logic here so
# host apply scripts stay orchestration-only.

function Test-NucleusPrimaryUser {
  <#
  .SYNOPSIS
    Returns whether the current Windows user is the configured primary user.

  .DESCRIPTION
    Compares the current interactive username against $PrimaryUsername.
    Secret materialization must only run for this primary user; non-primary
    users are always skipped.

  .PARAMETER PrimaryUsername
    Canonical primary username (for example: 'polyipseity').

  .PARAMETER Quiet
    Suppress the skip warning when the username does not match.

  .OUTPUTS
    [bool]  True when current user matches $PrimaryUsername.
  #>
  param(
    [Parameter(Mandatory = $true)]
    [string]$PrimaryUsername,

    [Parameter()]
    [switch]$Quiet
  )

  $currentUsername = [System.Environment]::UserName
  if ($currentUsername -eq $PrimaryUsername) {
    return $true
  }

  if (-not $Quiet) {
    Write-Host "Skipping secret materialization for non-primary user '$currentUsername'. Expected '$PrimaryUsername'." -ForegroundColor Yellow
  }

  return $false
}

function Sync-NucleusSecretFile {
  <#
  .SYNOPSIS
    Decrypts one SOPS secret file and materializes its payloads on disk.

  .DESCRIPTION
    Calls Get-NucleusSecrets to decrypt $FilePath, then processes five
    username-scoped flat keys:

    ssh_personal_${username}
      Written to $HOME\.ssh\ssh_personal_${username} using ASCII encoding
      (no BOM, no trailing newline). The file is only overwritten when content
      changes.

    ssh_personal_${username}_pub
      Written to $HOME\.ssh\ssh_personal_${username}.pub using ASCII encoding
      (no BOM, no trailing newline). The file is only overwritten when content
      changes.

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
      No temporary plaintext files are created.

    $HOME\.ssh is created if it does not already exist.

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
    Sync-NucleusSecretFile -FilePath '.\ssh-personal.yml' -GpgExe 'gpg.exe' `
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

  if (-not (Test-NucleusPrimaryUser -PrimaryUsername $PrimaryUsername -Quiet)) {
    return
  }

  $secretFileInfo = Get-Item -Path $FilePath
  $gpgSecretName = "gpg_personal_$PrimaryUsername"
  $sshDir = Join-Path -Path $HOME -ChildPath ".ssh"
  $sshPublicSecretName = "ssh_personal_${PrimaryUsername}_pub"
  $sshRsaPublicSecretName = "ssh_personal_${PrimaryUsername}_rsa_pub"
  $sshRsaSecretName = "ssh_personal_${PrimaryUsername}_rsa"
  $sshSecretName = "ssh_personal_$PrimaryUsername"

  if (-not (Test-Path -Path $sshDir)) {
    New-Item -ItemType Directory -Path $sshDir -Force | Out-Null
  }

  Write-Host "Processing secrets from: $($secretFileInfo.Name)" -ForegroundColor Cyan
  $jsonSecrets = Get-NucleusSecrets -FilePath $secretFileInfo.FullName -GpgExe $GpgExe -HostKeyPath $HostKeyPath -PrimarySshKeyPath $PrimarySshKeyPath -SopsExe $SopsExe

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
      $showOnlyOutput = $gpgKeyValue | & $GpgExe --batch --import-options show-only --dry-run --with-colons --import - 2>$null
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

      "${firstFingerprint}:6:" | & $GpgExe --import-ownertrust | Out-Null
      if ($LASTEXITCODE -ne 0) {
        throw "Failed to enforce ultimate ownertrust for managed primary fingerprint '$firstFingerprint'. Exit code: $LASTEXITCODE"
      }

      Write-Host "  Imported GPG material: $gpgSecretName" -ForegroundColor Cyan
    }
  }
}

function Invoke-NucleusJitSecretMaterialization {
  <#
  .SYNOPSIS
    Materializes a specific subset of named secret files on demand (JIT).

  .DESCRIPTION
    Designed for modules that need exactly one or two secrets rather than the
    full batch sync.  For each name in $SecretNames, the function resolves the
    corresponding .yml file under $SecretsDir (appending .yml if omitted) and
    calls Sync-NucleusSecretFile.  Throws immediately if a requested secret
    file does not exist.

  .PARAMETER SecretsDir
    Absolute path to the directory containing SOPS-encrypted YAML files.

  .PARAMETER SecretNames
    Names of the secret files to materialize.  The .yml extension is optional;
    it is appended automatically if not present.

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
    Invoke-NucleusJitSecretMaterialization -SecretsDir '.\secrets' `
      -SecretNames @('gpg-personal', 'ssh-personal') `
      -GpgExe 'gpg.exe' -HostKeyPath '...\ssh_host_ed25519_key' `
      -PrimarySshKeyPath "$HOME\.ssh\ssh_personal_polyipseity" -SopsExe 'sops.exe' `
      -PrimaryUsername 'polyipseity'
  #>
  param(
    [Parameter(Mandatory = $true)]
    [string]$SecretsDir,

    [Parameter(Mandatory = $true)]
    [string[]]$SecretNames,

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

  if (-not (Test-NucleusPrimaryUser -PrimaryUsername $PrimaryUsername)) {
    return
  }

  foreach ($secretName in $SecretNames) {
    $normalizedSecretFile = if ($secretName.EndsWith(".yml")) { $secretName } else { "$secretName.yml" }
    $secretPath = Join-Path -Path $SecretsDir -ChildPath $normalizedSecretFile

    if (-not (Test-Path -Path $secretPath)) {
      throw "Requested JIT secret file was not found: $secretPath"
    }

    Sync-NucleusSecretFile -FilePath $secretPath -GpgExe $GpgExe -HostKeyPath $HostKeyPath -PrimarySshKeyPath $PrimarySshKeyPath -SopsExe $SopsExe -PrimaryUsername $PrimaryUsername
  }
}

function Sync-NucleusSecrets {
  <#
  .SYNOPSIS
    Materializes primary-user personal SSH/GPG secrets from fixed secret files.

  .DESCRIPTION
    Resolves exactly two secret files from $SecretsDir (sorted):
      - gpg-personal.yml
      - ssh-personal.yml

    Each file is passed to Sync-NucleusSecretFile, which extracts only
    primary-user keys (`gpg_personal_${username}`, `ssh_personal_${username}`,
    `ssh_personal_${username}_pub`, `ssh_personal_${username}_rsa`, and
    `ssh_personal_${username}_rsa_pub`) and ignores all other keys.

  .PARAMETER SecretsDir
    Absolute path to the directory containing SOPS-encrypted YAML files.

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
    Sync-NucleusSecrets -SecretsDir '.\secrets' -GpgExe 'gpg.exe' `
      -HostKeyPath 'C:\ProgramData\ssh\ssh_host_ed25519_key' `
      -PrimarySshKeyPath "$HOME\.ssh\ssh_personal_polyipseity" -SopsExe 'sops.exe' `
      -PrimaryUsername 'polyipseity'
  #>
  param(
    [Parameter(Mandatory = $true)]
    [string]$SecretsDir,

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

  if (-not (Test-NucleusPrimaryUser -PrimaryUsername $PrimaryUsername)) {
    return
  }

  if (-not (Test-Path -Path $SecretsDir)) {
    Write-Host "No secrets directory found at $SecretsDir; skipping key provisioning." -ForegroundColor Yellow
    return
  }

  foreach ($secretFileName in @("gpg-personal.yml", "ssh-personal.yml")) {
    $secretPath = Join-Path -Path $SecretsDir -ChildPath $secretFileName
    if (-not (Test-Path -Path $secretPath)) {
      Write-Host "Required secret file was not found: $secretPath" -ForegroundColor Yellow
      continue
    }

    Sync-NucleusSecretFile -FilePath $secretPath -GpgExe $GpgExe -HostKeyPath $HostKeyPath -PrimarySshKeyPath $PrimarySshKeyPath -SopsExe $SopsExe -PrimaryUsername $PrimaryUsername
  }
}

function Remove-NucleusManagedSecrets {
  <#
  .SYNOPSIS
    Removes managed SSH key material for the primary user.

  .DESCRIPTION
    Cleanup companion for secret parity toggles. Removes only files managed by
    this repository (`ssh_personal_<user>`, `ssh_personal_<user>_rsa`, and
    corresponding `.pub` files) from the primary user's `~/.ssh` directory.

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
      (Join-Path -Path $sshDir -ChildPath "${sshRsaSecretName}.pub")
    )) {
    if (Test-Path -Path $managedPath) {
      Remove-Item -Path $managedPath -Force -ErrorAction SilentlyContinue
    }
  }
}
