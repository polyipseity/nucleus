<#
.SYNOPSIS
    Per-file SOPS secret materialization for managed SSH/GPG payloads.

.DESCRIPTION
    Decrypts one SOPS file and converges prefix-driven payloads for the
    configured user.  Also maintains managed-key manifest files in
    ~/.config/nucleus/ to enable rotation detection and agent flush on rotation,
    mirroring the POSIX gpg-import and ssh-key-adopt Home Manager activations.

.NOTES
    Environment variables: (none)
    Exit codes: N/A — library script; functions use throw on failure.
#>

function Sync-SecretFile {
  <#
  .SYNOPSIS
    Decrypts one SOPS secret file and materializes its payloads on disk.

  .DESCRIPTION
    Calls Get-Secret to decrypt $FilePath once, then processes prefix-driven
    keys:

    gpg_*
      Imported into the current GPG keyring via stdin (`gpg --batch --import -`).
      The managed primary fingerprint is recorded in
      $HOME\.config\nucleus\managed-gpg-keys.

    ssh_*
      Prefix is stripped and the remainder is written under $HOME\.ssh\
      (for example ssh_ssh_personal_admin -> ssh_personal_admin). Private key
      paths are recorded in $HOME\.config\nucleus\managed-ssh-key-paths.
      Public keys update $HOME\.config\nucleus\managed-ssh-keys for rotation
      detection and SSH agent flush.

    git_identity
      Written to $HOME\.config\nucleus\git-identity.env.

    rclone_config_pass
      Written to $HOME\.config\nucleus\secrets\rclone-config-pass.

  .PARAMETER FilePath
    Absolute path to the SOPS-encrypted YAML file.

  .PARAMETER GpgExe
    Absolute path to the gpg executable.

  .PARAMETER HostKeyPath
    Path to this machine's SSH host private key used as the age decryption key.

  .PARAMETER RepoRoot
    Absolute path to the nucleus repository root.

  .PARAMETER SopsExe
    Absolute path to the sops executable.

  .PARAMETER Username
    Username whose home directory receives materialized payloads.

  .PARAMETER SshKeyFallbackPath
    Optional SSH private key path used when machine age key and user manifests are unavailable.

  .EXAMPLE
    Sync-SecretFile -FilePath '.\polyipseity.yml' -GpgExe 'gpg.exe' `
      -HostKeyPath 'C:\ProgramData\ssh\ssh_host_ed25519_key' `
      -RepoRoot 'C:\Users\admin\nucleus' -SopsExe 'sops.exe' `
      -Username 'polyipseity'

  .NOTES
    Environment variables: (none)
    Exit codes: N/A — library function; uses throw on failure.
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
    [string]$SopsExe,

    [Parameter(Mandatory = $true)]
    [string]$Username,

    [string]$SshKeyFallbackPath
  )

  $userHome = Resolve-SecretUserHomedir -Username $Username
  if ([string]::IsNullOrWhiteSpace($userHome)) {
    throw "secrets: could not resolve home directory for user '$Username'."
  }

  $secretFileInfo = Get-Item -Path $FilePath
  $configDir = Join-Path -Path $userHome -ChildPath '.config\nucleus'
  $gitIdentityPath = Join-Path -Path $configDir -ChildPath 'git-identity.env'
  $managedGpgKeysManifest = Join-Path -Path $configDir -ChildPath 'managed-gpg-keys'
  $managedSshKeysManifest = Join-Path -Path $configDir -ChildPath 'managed-ssh-keys'
  $managedSshKeyPathsManifest = Join-Path -Path $configDir -ChildPath 'managed-ssh-key-paths'
  $rclonePassPath = Join-Path -Path $configDir -ChildPath 'secrets\rclone-config-pass'
  $sshDir = Join-Path -Path $userHome -ChildPath '.ssh'
  $managedSshPrivateKeyPaths = [System.Collections.Generic.List[string]]::new()

  if (-not (Test-Path -Path $sshDir)) {
    New-Item -ItemType Directory -Path $sshDir -Force > $null
  }

  if (-not (Test-Path -Path $configDir)) {
    New-Item -ItemType Directory -Path $configDir -Force > $null
  }

  $previousGpgHome = $env:GNUPGHOME
  $targetGpgHome = Join-Path -Path $userHome -ChildPath '.gnupg'
  if ($Username -ne $env:USERNAME) {
    if (-not (Test-Path -Path $targetGpgHome)) {
      New-Item -ItemType Directory -Path $targetGpgHome -Force > $null
    }
    $env:GNUPGHOME = $targetGpgHome
  }

  try {
  $rclonePassDir = Split-Path -Path $rclonePassPath -Parent
  if (-not (Test-Path -Path $rclonePassDir)) {
    New-Item -ItemType Directory -Path $rclonePassDir -Force > $null
  }

  $restrictAcl = {
    param([string]$Path)
    $currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    & icacls.exe $Path /inheritance:r /grant:r "${currentUser}:(F)" > $null
    if ($LASTEXITCODE -ne 0) {
      Write-NucleusError -CommandName 'secrets' "could not restrict ACL on $Path (icacls exit $LASTEXITCODE)"
      throw
    }
  }

  $restrictAclReadOnly = {
    param([string]$Path)
    $acl = Get-Acl -Path $Path
    $acl.SetAccessRuleProtection($true, $false)
    $currentIdentity = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
      $currentIdentity, 'Read', 'Allow'
    )
    $acl.SetAccessRule($rule)
    Set-Acl -Path $Path -AclObject $acl
  }

  Write-NucleusInfo -CommandName 'secrets' "Processing secrets from: $($secretFileInfo.Name)"
  $getSecretParams = @{
    FilePath           = $secretFileInfo.FullName
    GpgExe             = $GpgExe
    HostKeyPath        = $HostKeyPath
    RepoRoot           = $RepoRoot
    SopsExe            = $SopsExe
  }
  if (-not [string]::IsNullOrWhiteSpace($SshKeyFallbackPath)) {
    $getSecretParams['PrimarySshKeyPath'] = $SshKeyFallbackPath
  }
  $jsonSecrets = Get-Secret @getSecretParams

  foreach ($property in $jsonSecrets.PSObject.Properties) {
    $secretKey = $property.Name
    $secretValue = [string]$property.Value

    if ($secretKey.StartsWith('gpg_')) {
      if ([string]::IsNullOrWhiteSpace($secretValue)) {
        continue
      }

      $firstFingerprint = $null
      $showOnlyOutput = $secretValue | & $GpgExe --batch --import-options show-only --dry-run --with-colons --import -
      foreach ($line in $showOnlyOutput) {
        if ($line -like 'fpr:*') {
          $parts = $line -split ':'
          if ($parts.Length -ge 10 -and -not [string]::IsNullOrWhiteSpace($parts[9])) {
            $firstFingerprint = $parts[9]
            break
          }
        }
      }

      $secretValue | & $GpgExe --batch --import - > $null
      if ($LASTEXITCODE -ne 0) {
        throw "Failed to import GPG material '$secretKey'. Exit code: $LASTEXITCODE"
      }

      if ([string]::IsNullOrWhiteSpace($firstFingerprint)) {
        throw "Imported GPG key material but no managed primary fingerprint was detected for ownertrust enforcement."
      }

      $firstFingerprint | Out-File -FilePath $managedGpgKeysManifest -Encoding ascii -NoNewline
      & $restrictAcl -Path $managedGpgKeysManifest

      "${firstFingerprint}:6:" | & $GpgExe --import-ownertrust > $null
      if ($LASTEXITCODE -ne 0) {
        Write-NucleusError -CommandName 'secrets' "ownertrust enforcement for '$firstFingerprint' exited $LASTEXITCODE — key imported and manifest updated, ownertrust may need a retry"
        throw
      }

      Write-NucleusInfo -CommandName 'secrets' "  Imported GPG material: $secretKey"
      continue
    }

    if ($secretKey.StartsWith('ssh_')) {
      $relativeSshPath = $secretKey.Substring(4)
      $sshKeyPath = Join-Path -Path $sshDir -ChildPath $relativeSshPath
      $sshKeyParent = Split-Path -Path $sshKeyPath -Parent
      if (-not (Test-Path -Path $sshKeyParent)) {
        New-Item -ItemType Directory -Path $sshKeyParent -Force > $null
      }

      $existingValue = if (Test-Path -Path $sshKeyPath) {
        Get-Content -Path $sshKeyPath -Raw
      }
      else {
        ''
      }

      if ($existingValue -ne $secretValue) {
        $secretValue | Out-File -FilePath $sshKeyPath -Encoding ascii -NoNewline
        Write-NucleusInfo -CommandName 'secrets' "  Updated SSH key: $relativeSshPath"
      }

      & $restrictAcl -Path $sshKeyPath

      if (-not $relativeSshPath.EndsWith('.pub')) {
        $managedSshPrivateKeyPaths.Add($sshKeyPath)
      }
      else {
        try {
          $sshKeyParts = $secretValue.Trim() -split '\s+'
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
              $sshAddCommand = Get-Command 'ssh-add' -ErrorAction SilentlyContinue  # check-suppress:suppression_doc: probe -- ssh-add may not be installed; $null check below handles absence
              if ($null -ne $sshAddCommand) {
                & $sshAddCommand.Source -D *> $null
                Write-NucleusInfo -CommandName 'secrets' "  Flushed SSH agent due to key rotation ($oldSshFingerprint -> $newSshFingerprint)"
              }
            }

            $newSshFingerprint | Out-File -FilePath $managedSshKeysManifest -Encoding ascii -NoNewline
            & $restrictAcl -Path $managedSshKeysManifest
          }
        }
        catch {
          Write-NucleusError -CommandName 'secrets' "could not update SSH fingerprint manifest: $_"
          throw
        }
      }

      continue
    }

    if ($secretKey -eq 'git_identity') {
      $existingIdentityValue = if (Test-Path -Path $gitIdentityPath) {
        Get-Content -Path $gitIdentityPath -Raw
      }
      else {
        ''
      }

      if ($existingIdentityValue -ne $secretValue) {
        $secretValue | Out-File -FilePath $gitIdentityPath -Encoding ascii -NoNewline
        Write-NucleusInfo -CommandName 'secrets' "  Updated Git identity payload: $secretKey"
      }

      & $restrictAcl -Path $gitIdentityPath
      continue
    }

    if ($secretKey -eq 'rclone_config_pass') {
      if ([string]::IsNullOrWhiteSpace($secretValue)) {
        continue
      }

      $existingRclonePass = if (Test-Path -Path $rclonePassPath -PathType Leaf) {
        Get-Content -Path $rclonePassPath -Raw -Encoding UTF8
      }
      else {
        $null
      }

      if ($existingRclonePass -ne $secretValue) {
        [System.IO.File]::WriteAllText($rclonePassPath, $secretValue, [System.Text.UTF8Encoding]::new($false))
        & $restrictAclReadOnly -Path $rclonePassPath
        Write-NucleusInfo -CommandName 'secrets' "  Updated rclone config passphrase"
      }
    }
  }

  if ($managedSshPrivateKeyPaths.Count -gt 0) {
    $managedSshPrivateKeyPaths |
      Sort-Object -Unique |
      Out-File -FilePath $managedSshKeyPathsManifest -Encoding ascii
    & $restrictAcl -Path $managedSshKeyPathsManifest
  }
  }
  finally {
    if ($Username -ne $env:USERNAME) {
      if ($null -ne $previousGpgHome) {
        $env:GNUPGHOME = $previousGpgHome
      }
      else {
        Remove-Item -Path Env:GNUPGHOME -ErrorAction SilentlyContinue  # check-suppress:suppression_doc: restore prior unset GNUPGHOME after cross-user materialization
      }
    }
  }
}
