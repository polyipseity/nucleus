# modules/windows/invoke-nucleussecretverification.ps1 — Post-apply secret health check.
#
# Mirrors the POSIX verifySecretDecryption Home Manager activation in secrets.nix.
# Verifies that all SOPS files can be decrypted by each registered backend (GPG
# and personal SSH age) and that managed secret artefacts are present on disk.

function Invoke-NucleusSecretVerification {
  <#
  .SYNOPSIS
    Post-apply health check that verifies all SOPS files are decryptable by
    each registered backend.

  .DESCRIPTION
    Runs five checks in order, mirroring the POSIX verifySecretDecryption
    activation in src/modules/secrets.nix:

    1. Materialization sanity: managed SSH key files, git-identity env, and
       managed-key manifest files exist and are non-empty.
    2. GPG key presence: the managed primary fingerprint recorded in the
       managed-gpg-keys manifest is present in the GPG keyring.
    3. GPG SOPS end-to-end: runs sops --decrypt on every SOPS file with age
       backends disabled (SOPS_AGE_KEY_FILE=NUL) so only the GPG recipient
       is exercised.  Accumulates failures and reports all failing files.
       Hard error — GPG is the last-resort global backup.
    4. Personal SSH age-backend SOPS end-to-end: runs sops --decrypt on every
       SOPS file with SOPS_AGE_SSH_PRIVATE_KEY_FILE pointing at the managed
       personal SSH key and GNUPGHOME pointing at an empty temp directory so
       only the age backend is exercised.  Accumulates failures.
       Hard error — the personal SSH key is the designated personal backup
       age recipient in .sops.yaml.
    5. Machine SSH host key existence: advisory warning if
       C:\ProgramData\ssh\ssh_host_ed25519_key is absent (warning-only because
       on first bootstrap the key may not yet be registered in .sops.yaml).

    Environment variables that influence SOPS backends are saved before each
    test block and restored in finally blocks so no state leaks into subsequent
    operations.

  .PARAMETER GpgExe
    Absolute path to the gpg executable.

  .PARAMETER HostKeyPath
    Path to this machine's SSH host private key (used only for the host-key
    existence advisory check).

  .PARAMETER PrimaryUsername
    Canonical primary username whose materialized files are inspected.

  .PARAMETER PrimarySshKeyPath
    Path to the primary user's managed SSH private key used as the personal
    SSH age recipient in check 4.

  .PARAMETER SecretsDir
    Absolute path to the directory containing the SOPS secret YAML files
    (src/secrets).

  .PARAMETER SopsExe
    Absolute path to the sops executable.

  .PARAMETER WallpaperAssetsDir
    Absolute path to the directory containing wallpaper SOPS blobs
    (src/assets/wallpapers).

  .EXAMPLE
    Invoke-NucleusSecretVerification `
      -GpgExe 'C:\Program Files\GnuPG\bin\gpg.exe' `
      -HostKeyPath 'C:\ProgramData\ssh\ssh_host_ed25519_key' `
      -PrimaryUsername 'polyipseity' `
      -PrimarySshKeyPath "$HOME\.ssh\ssh_personal_polyipseity" `
      -SecretsDir '.\src\secrets' `
      -SopsExe 'sops.exe' `
      -WallpaperAssetsDir '.\src\assets\wallpapers'
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)]
    [string]$GpgExe,

    [Parameter(Mandatory = $true)]
    [string]$HostKeyPath,

    [Parameter(Mandatory = $true)]
    [string]$PrimaryUsername,

    [Parameter(Mandatory = $true)]
    [string]$PrimarySshKeyPath,

    [Parameter(Mandatory = $true)]
    [string]$SecretsDir,

    [Parameter(Mandatory = $true)]
    [string]$SopsExe,

    [Parameter(Mandatory = $true)]
    [string]$WallpaperAssetsDir
  )

  if (-not (Test-NucleusPrimaryUser -PrimaryUsername $PrimaryUsername -Quiet)) {
    return
  }

  Write-Host "nucleus: running post-apply secret verification..." -ForegroundColor Cyan

  $nucleusConfigDir = Join-Path -Path $HOME -ChildPath ".config\nucleus"
  $managedGpgKeysManifest = Join-Path -Path $nucleusConfigDir -ChildPath "managed-gpg-keys"
  $managedSshKeysManifest = Join-Path -Path $nucleusConfigDir -ChildPath "managed-ssh-keys"
  $gitIdentityPath = Join-Path -Path $nucleusConfigDir -ChildPath "git-identity.env"
  $sshDir = Join-Path -Path $HOME -ChildPath ".ssh"
  $sshKeyPath = Join-Path -Path $sshDir -ChildPath "ssh_personal_$PrimaryUsername"
  $sshPublicKeyPath = Join-Path -Path $sshDir -ChildPath "ssh_personal_$PrimaryUsername.pub"

  # Enumerate all SOPS files to test: the three secret YAMLs plus every
  # *.sops blob in the wallpapers directory.  This mirrors the dynamic
  # builtins.readDir enumeration in the POSIX verifySecretDecryption.
  $sopsTestFiles = @(
    (Join-Path -Path $SecretsDir -ChildPath "git-identities.yml"),
    (Join-Path -Path $SecretsDir -ChildPath "gpg-personal.yml"),
    (Join-Path -Path $SecretsDir -ChildPath "ssh-personal.yml")
  )
  if (Test-Path -Path $WallpaperAssetsDir) {
    $wallpaperSopsFiles = Get-ChildItem -Path $WallpaperAssetsDir -Filter "*.sops" -File -ErrorAction SilentlyContinue |
      Select-Object -ExpandProperty FullName
    if ($null -ne $wallpaperSopsFiles) {
      $sopsTestFiles += $wallpaperSopsFiles
    }
  }

  # -------------------------------------------------------------------------
  # 1. Materialization sanity: key files must exist and be non-empty.
  # -------------------------------------------------------------------------
  Write-Host "nucleus: [1/5] checking secret materialization..." -ForegroundColor Gray
  $sanityPaths = @($sshKeyPath, $sshPublicKeyPath, $managedGpgKeysManifest, $managedSshKeysManifest, $gitIdentityPath)
  foreach ($sanityPath in $sanityPaths) {
    if (-not (Test-Path -Path $sanityPath) -or (Get-Item -Path $sanityPath).Length -eq 0) {
      throw "nucleus: ERROR — managed secret artefact missing or empty: $sanityPath"
    }
  }
  Write-Host "nucleus: [1/5] materialization sanity: OK" -ForegroundColor Green

  # -------------------------------------------------------------------------
  # 2. GPG key presence: the managed fingerprint must be in the keyring.
  # -------------------------------------------------------------------------
  Write-Host "nucleus: [2/5] checking GPG key presence..." -ForegroundColor Gray
  $managedFpr = (Get-Content -Path $managedGpgKeysManifest -Raw).Trim()
  if ([string]::IsNullOrWhiteSpace($managedFpr)) {
    throw "nucleus: ERROR — managed-gpg-keys manifest is empty; gpgImport may have failed."
  }
  $gpgListOutput = & $GpgExe --batch --list-secret-keys $managedFpr 2>&1
  if ($LASTEXITCODE -ne 0) {
    throw "nucleus: ERROR — managed GPG key $managedFpr not in keyring after materialization."
  }
  Write-Host "nucleus: [2/5] GPG key presence: OK ($managedFpr)" -ForegroundColor Green

  # -------------------------------------------------------------------------
  # 3. GPG SOPS end-to-end check for all SOPS files.
  # Disable age backends so only the GPG recipient is exercised.
  # Environment variables are restored in the finally block so no state leaks.
  # -------------------------------------------------------------------------
  Write-Host "nucleus: [3/5] checking GPG SOPS decryption for all SOPS files..." -ForegroundColor Gray
  $gpgFailures = @()
  $savedAgeKeyFile = $env:SOPS_AGE_KEY_FILE
  $savedAgeKey = $env:SOPS_AGE_KEY
  $savedAgeSshKey = $env:SOPS_AGE_SSH_PRIVATE_KEY_FILE
  try {
    # NUL is the Windows null device; directing sops to it disables age key file.
    $env:SOPS_AGE_KEY_FILE = 'NUL'
    $env:SOPS_AGE_KEY = ''
    Remove-Item Env:SOPS_AGE_SSH_PRIVATE_KEY_FILE -ErrorAction SilentlyContinue

    foreach ($sopsFile in $sopsTestFiles) {
      $decryptOutput = & $SopsExe --decrypt $sopsFile 2>&1
      if ($LASTEXITCODE -ne 0) {
        $gpgFailures += [System.IO.Path]::GetFileName($sopsFile)
      }
    }
  }
  finally {
    # Always restore age env vars whether or not decryption succeeded.
    if ($null -ne $savedAgeKeyFile) { $env:SOPS_AGE_KEY_FILE = $savedAgeKeyFile }
    else { Remove-Item Env:SOPS_AGE_KEY_FILE -ErrorAction SilentlyContinue }
    if ($null -ne $savedAgeKey) { $env:SOPS_AGE_KEY = $savedAgeKey }
    else { Remove-Item Env:SOPS_AGE_KEY -ErrorAction SilentlyContinue }
    if ($null -ne $savedAgeSshKey) { $env:SOPS_AGE_SSH_PRIVATE_KEY_FILE = $savedAgeSshKey }
    else { Remove-Item Env:SOPS_AGE_SSH_PRIVATE_KEY_FILE -ErrorAction SilentlyContinue }
  }
  if ($gpgFailures.Count -gt 0) {
    throw "nucleus: ERROR — GPG SOPS decryption check failed for: $($gpgFailures -join ', '); managed GPG key may not be registered in .sops.yaml."
  }
  Write-Host "nucleus: [3/5] GPG SOPS end-to-end: OK" -ForegroundColor Green

  # -------------------------------------------------------------------------
  # 4. Personal SSH age-backend SOPS end-to-end check for all SOPS files.
  # Point SOPS_AGE_SSH_PRIVATE_KEY_FILE at the managed SSH key and disable
  # GPG by pointing GNUPGHOME at an empty temp directory.
  # Environment variables and temp dir are cleaned up in the finally block.
  # -------------------------------------------------------------------------
  Write-Host "nucleus: [4/5] checking personal SSH age-backend SOPS decryption..." -ForegroundColor Gray
  if (-not (Test-Path -Path $PrimarySshKeyPath)) {
    throw "nucleus: ERROR — managed personal SSH key not found at $PrimarySshKeyPath; cannot test SSH age backend."
  }
  $sshFailures = @()
  $tempGnupgHome = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ([System.IO.Path]::GetRandomFileName())
  New-Item -ItemType Directory -Path $tempGnupgHome | Out-Null
  $savedGnupgHome = $env:GNUPGHOME
  try {
    # Empty GNUPGHOME prevents GnuPG from finding any secret keys, forcing
    # SOPS to rely solely on the SSH age backend for decryption.
    $env:GNUPGHOME = $tempGnupgHome
    $env:SOPS_AGE_SSH_PRIVATE_KEY_FILE = $PrimarySshKeyPath
    Remove-Item Env:SOPS_AGE_KEY_FILE -ErrorAction SilentlyContinue
    Remove-Item Env:SOPS_AGE_KEY -ErrorAction SilentlyContinue

    foreach ($sopsFile in $sopsTestFiles) {
      $decryptOutput = & $SopsExe --decrypt $sopsFile 2>&1
      if ($LASTEXITCODE -ne 0) {
        $sshFailures += [System.IO.Path]::GetFileName($sopsFile)
      }
    }
  }
  finally {
    # Always restore GNUPGHOME and clear SSH key var; remove the isolated temp dir.
    if ($null -ne $savedGnupgHome) { $env:GNUPGHOME = $savedGnupgHome }
    else { Remove-Item Env:GNUPGHOME -ErrorAction SilentlyContinue }
    Remove-Item Env:SOPS_AGE_SSH_PRIVATE_KEY_FILE -ErrorAction SilentlyContinue
    Remove-Item -Recurse -Force -Path $tempGnupgHome -ErrorAction SilentlyContinue
  }
  if ($sshFailures.Count -gt 0) {
    throw "nucleus: ERROR — personal SSH key age-backend SOPS decryption check failed for: $($sshFailures -join ', '); SSH key may not be registered in .sops.yaml as an age recipient."
  }
  Write-Host "nucleus: [4/5] SSH age SOPS end-to-end: OK" -ForegroundColor Green

  # -------------------------------------------------------------------------
  # 5. Machine SSH host key existence check (advisory warning only).
  # Warning-only: on first bootstrap the host key may not yet be registered
  # in .sops.yaml.  See the bootstrap instructions in secrets.nix.
  # -------------------------------------------------------------------------
  Write-Host "nucleus: [5/5] checking machine SSH host key..." -ForegroundColor Gray
  if (-not (Test-Path -Path $HostKeyPath)) {
    Write-Warning "nucleus: $HostKeyPath missing; this machine cannot be the primary SOPS age recipient until the host key is registered in .sops.yaml."
  }
  else {
    Write-Host "nucleus: [5/5] machine SSH host key: present ($HostKeyPath)" -ForegroundColor Green
  }

  Write-Host "nucleus: post-apply secret verification passed." -ForegroundColor Green
}
