<#
.SYNOPSIS
    Post-apply secret health check for SOPS file recipient verification.

.DESCRIPTION
    Mirrors the POSIX verify-secret-decryption Home Manager activation in secrets.nix.
    Verifies that all SOPS files have the correct recipients registered and that
    managed secret artefacts are present on disk.  Uses metadata inspection rather
    than live decryption so passphrase-protected keys do not cause false failures.

    ConvertFrom-SshEd25519PublicKeyToAgePubKey is provided by
    convert-sshpublickeytoage.ps1, which apply.ps1 dot-sources before this file
    (alphabetical order ensures 'c' < 'i').

.NOTES
    Environment variables: (none)
    Exit codes: N/A — library script; functions use throw on failure.
#>

function Invoke-SecretVerification {
  <#
  .SYNOPSIS
    Post-apply health check that verifies all SOPS files are decryptable by
    each registered backend.

  .DESCRIPTION
    Runs five checks in order, mirroring the POSIX verify-secret-decryption
    activation in src/modules/secrets.nix:

    1. Materialization sanity: managed SSH key files, git-identity env, and
       managed-key manifest files exist and are non-empty.
    2. GPG key presence: the managed primary fingerprint recorded in the
       managed-gpg-keys manifest is present in the GPG keyring.
    3. GPG SOPS recipient check: extracts the fp: value from each SOPS
       file's plaintext sops.pgp[].fp metadata and verifies that fingerprint
       is present in the secret keyring.  SOPS records the encryption subkey
       fingerprint rather than the primary key fingerprint in the fp: field;
       comparing the primary fingerprint directly produces false failures when
       SOPS chose a subkey (e.g., a Kyber encryption subkey).
       Combined with check 2, this confirms GPG has the private key material
       to decrypt once the passphrase is provided.
       Accumulates failures and reports all failing files.
       Hard error — GPG is the last-resort global backup.
    4. Personal SSH age recipient check: derives the age public key from the
       managed personal SSH public key file (passphrase-free public-key
       conversion via ConvertFrom-SshEd25519PublicKeyToAgePubKey), then
       searches each SOPS file's plaintext sops.age[].recipient metadata for
       that key.  No private key passphrase is required.
       Accumulates failures and reports all failing files.
       Hard error — the personal SSH key is the designated personal backup
       age recipient in .sops.yaml.
    5. Machine SSH host key existence: advisory warning if
       C:\ProgramData\ssh\ssh_host_ed25519_key is absent (warning-only because
       on first bootstrap the key may not yet be registered in .sops.yaml).

  .PARAMETER GpgExe
    Absolute path to the gpg executable.

  .PARAMETER HostKeyPath
    Path to this machine's SSH host private key (used only for the host-key
    existence advisory check).

  .PARAMETER Username
    Username whose materialized secret artefacts are inspected.

  .PARAMETER SecretsDir
    Absolute path to the directory containing the SOPS secret YAML files
    (src/secrets).

  .PARAMETER RepoRoot
    Absolute path to the nucleus repository root (overlay wallpapers enumerated
    from src/users/<user>/wallpapers/).

  .EXAMPLE
    Invoke-SecretVerification `
      -GpgExe 'C:\Program Files\GnuPG\bin\gpg.exe' `
      -HostKeyPath 'C:\ProgramData\ssh\ssh_host_ed25519_key' `
      -Username 'admin' `
      -SecretsDir '.\src\secrets' `
      -RepoRoot '.\'

  .NOTES
    Environment variables: (none)
    Exit codes: N/A — library function; throws on failure.
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)]
    [string]$GpgExe,

    [Parameter(Mandatory = $true)]
    [string]$HostKeyPath,

    [Parameter(Mandatory = $true)]
    [string]$Username,

    [Parameter(Mandatory = $true)]
    [string]$SecretsDir,

    [Parameter(Mandatory = $true)]
    [string]$RepoRoot
  )

  Write-Output "$($PSStyle.Foreground.Cyan)verification: running post-apply secret verification...$($PSStyle.Foreground.Default)"

  $userHome = Resolve-SecretUserHomedir -Username $Username
  if ([string]::IsNullOrWhiteSpace($userHome)) {
    throw "verification: ERROR — could not resolve home directory for user '$Username'."
  }

  $configDir = Join-Path -Path $userHome -ChildPath '.config\nucleus'
  $managedGpgKeysManifest = Join-Path -Path $configDir -ChildPath 'managed-gpg-keys'
  $managedSshKeysManifest = Join-Path -Path $configDir -ChildPath 'managed-ssh-keys'
  $managedSshKeyPathsManifest = Join-Path -Path $configDir -ChildPath 'managed-ssh-key-paths'
  $gitIdentityPath = Join-Path -Path $configDir -ChildPath 'git-identity.env'
  $sshDir = Join-Path -Path $userHome -ChildPath '.ssh'
  $sshKeyPath = Join-Path -Path $sshDir -ChildPath "ssh_personal_$Username"
  $sshPublicKeyPath = Join-Path -Path $sshDir -ChildPath "ssh_personal_$Username.pub"

  $sopsTestFiles = @()
  $systemYmlPath = Join-Path -Path $SecretsDir -ChildPath 'system.yml'
  if (Test-Path -Path $systemYmlPath -PathType Leaf) {
    $sopsTestFiles += $systemYmlPath
  }

  $usersSecretsDir = Join-Path -Path $SecretsDir -ChildPath 'users'
  if (Test-Path -Path $usersSecretsDir) {
    $userSecretFiles = Get-ChildItem -Path $usersSecretsDir -Filter '*.yml' -File -ErrorAction SilentlyContinue  # check-suppress:suppression_doc: probe -- users dir may have no .yml files; null check below handles absence
    if ($null -ne $userSecretFiles) {
      $userSecretFiles = $userSecretFiles | Select-Object -ExpandProperty FullName
      $sopsTestFiles += $userSecretFiles
    }
  }
  $usersRoot = Join-Path -Path $RepoRoot -ChildPath 'src\users'
  if (Test-Path -Path $usersRoot) {
    $wallpaperSopsFiles = @(Get-ChildItem -Path $usersRoot -Recurse -Filter '*.sops' -File -ErrorAction SilentlyContinue |
      Where-Object { $_.FullName -match '[\\/]wallpapers[\\/]encrypted[\\/]' })
    if ($wallpaperSopsFiles.Count -gt 0) {
      $sopsTestFiles += @($wallpaperSopsFiles | Select-Object -ExpandProperty FullName)
    }
  }

  # -------------------------------------------------------------------------
  # 1. Materialization sanity: key files must exist and be non-empty.
  # -------------------------------------------------------------------------
  Write-Output "$($PSStyle.Foreground.BrightBlack)verification: [1/5] checking secret materialization...$($PSStyle.Foreground.Default)"
  $sanityPaths = @($sshKeyPath, $sshPublicKeyPath, $managedGpgKeysManifest, $managedSshKeysManifest, $managedSshKeyPathsManifest, $gitIdentityPath)
  foreach ($sanityPath in $sanityPaths) {
    if (-not (Test-Path -Path $sanityPath) -or (Get-Item -Path $sanityPath).Length -eq 0) {
      throw "verification: ERROR — managed secret artefact missing or empty: $sanityPath"
    }
  }
  Write-Output "$($PSStyle.Foreground.Green)verification: [1/5] materialization sanity: OK$($PSStyle.Foreground.Default)"

  # -------------------------------------------------------------------------
  # 2. GPG key presence: the managed fingerprint must be in the keyring.
  # -------------------------------------------------------------------------
  Write-Output "$($PSStyle.Foreground.BrightBlack)verification: [2/5] checking GPG key presence...$($PSStyle.Foreground.Default)"
  $managedFpr = (Get-Content -Path $managedGpgKeysManifest -Raw).Trim()
  if ([string]::IsNullOrWhiteSpace($managedFpr)) {
    throw "verification: ERROR — managed-gpg-keys manifest is empty; gpg-import may have failed."
  }
  $allSecretKeysFpr = (& $GpgExe --with-colons --no-autostart --list-secret-keys 2>&1) -join "`n"
  if (-not ($allSecretKeysFpr -like "*$managedFpr*")) {
    throw "verification: ERROR — managed GPG key $managedFpr not in keyring after materialization."
  }
  Write-Output "$($PSStyle.Foreground.Green)verification: [2/5] GPG key presence: OK ($managedFpr)$($PSStyle.Foreground.Default)"

  # -------------------------------------------------------------------------
  # 3. GPG SOPS recipient check for all SOPS files.
  # Extract the fp: value from each file's unencrypted sops.pgp[].fp metadata
  # and verify that fingerprint is present in the secret keyring.  SOPS records
  # the encryption subkey fingerprint rather than the primary key fingerprint;
  # comparing the primary fingerprint directly produces false failures when SOPS
  # chose a subkey (e.g., a Kyber encryption subkey).  Combined with check 2,
  # this confirms GPG has the private key material to decrypt.
  # YAML SOPS files store fp as "    fp: HEX" (whitespace-prefixed, unquoted);
  # binary SOPS files (e.g. wallpaper blobs) use JSON format with
  # "\"fp\": \"HEX\"" (quoted key and value).  Both formats are handled below.
  # -------------------------------------------------------------------------
  Write-Output "$($PSStyle.Foreground.BrightBlack)verification: [3/5] checking GPG recipient registration in all SOPS files...$($PSStyle.Foreground.Default)"
  $gpgFailures = @()
  foreach ($sopsFile in $sopsTestFiles) {
    # The combined regex matches both YAML (\s+fp:) and JSON ("fp":) formats.
    # [regex]::Match extracts the hex fingerprint directly, so no separate
    # quote-stripping step is needed for JSON-encoded values.
    $fpLine = Get-Content -Path $sopsFile | Where-Object { $_ -match '(?:\s+fp:|\s*"fp":)\s' } | Select-Object -First 1
    $sopsGpgFp = if ($fpLine) { [regex]::Match($fpLine, '[0-9A-Fa-f]{40,}').Value } else { '' }
    if ([string]::IsNullOrWhiteSpace($sopsGpgFp) -or -not ($allSecretKeysFpr -like "*$sopsGpgFp*")) {
      $gpgFailures += [System.IO.Path]::GetFileName($sopsFile)
    }
  }
  if ($gpgFailures.Count -gt 0) {
    throw "verification: ERROR — GPG SOPS decryption check failed for: $($gpgFailures -join ', '); managed GPG key may not be registered in .sops.yaml."
  }
  Write-Output "$($PSStyle.Foreground.Green)verification: [3/5] GPG SOPS recipient check: OK$($PSStyle.Foreground.Default)"

  # -------------------------------------------------------------------------
  # 4. Personal SSH age recipient check for all SOPS files.
  # Derive the age public key from the managed SSH public key file (passphrase-
  # free; the public key carries no secret material) and search each SOPS
  # file's plaintext sops.age[] metadata for the derived key value.
  # YAML SOPS files store the key as "recipient: age1..." (unquoted); binary
  # SOPS files (e.g. wallpaper blobs) use JSON format with both the key name
  # and value double-quoted.  Searching for the bare age key value handles both.
  # -------------------------------------------------------------------------
  Write-Output "$($PSStyle.Foreground.BrightBlack)verification: [4/5] checking personal SSH age recipient registration in all SOPS files...$($PSStyle.Foreground.Default)"
  if (-not (Test-Path -Path $sshPublicKeyPath)) {
    throw "verification: ERROR — managed personal SSH public key not found at $sshPublicKeyPath; cannot derive age public key for recipient check."
  }
  $sshPubKeyLine = (Get-Content -Path $sshPublicKeyPath -Raw).Trim()
  $sshAgePub = ConvertFrom-SshEd25519PublicKeyToAgePubKey -SshPublicKeyLine $sshPubKeyLine
  $sshFailures = @()
  foreach ($sopsFile in $sopsTestFiles) {
    $hasSshRecipient = Select-String -Path $sopsFile -Pattern $sshAgePub -SimpleMatch -Quiet -ErrorAction SilentlyContinue  # check-suppress:suppression_doc: probe -- SOPS file may not contain this recipient; returns $false when absent
    if (-not $hasSshRecipient) {
      $sshFailures += [System.IO.Path]::GetFileName($sopsFile)
    }
  }
  if ($sshFailures.Count -gt 0) {
    throw "verification: ERROR — personal SSH key age-backend SOPS decryption check failed for: $($sshFailures -join ', '); SSH key may not be registered in .sops.yaml as an age recipient."
  }
  Write-Output "$($PSStyle.Foreground.Green)verification: [4/5] SSH age SOPS recipient check: OK ($sshAgePub)$($PSStyle.Foreground.Default)"

  # -------------------------------------------------------------------------
  # 5. Machine SSH host key existence check (advisory warning only).
  # -------------------------------------------------------------------------
  Write-Output "$($PSStyle.Foreground.BrightBlack)verification: [5/5] checking machine SSH host key...$($PSStyle.Foreground.Default)"
  if (-not (Test-Path -Path $HostKeyPath)) {
    Write-Warning "verification: $HostKeyPath missing; this machine cannot be the primary SOPS age recipient until the host key is registered in .sops.yaml."
  }
  else {
    Write-Output "$($PSStyle.Foreground.Green)verification: [5/5] machine SSH host key: present ($HostKeyPath)$($PSStyle.Foreground.Default)"
  }

  Write-Output "$($PSStyle.Foreground.Green)verification: post-apply secret verification passed.$($PSStyle.Foreground.Default)"
}
