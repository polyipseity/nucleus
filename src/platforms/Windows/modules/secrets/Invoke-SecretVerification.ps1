<#
.SYNOPSIS
    Post-apply secret health check for SOPS file recipient verification.

.DESCRIPTION
    Mirrors the POSIX verify-secret-decryption Home Manager activation in secrets.nix.
    Verifies that all SOPS files have the correct recipients registered and that
    managed secret artefacts are present on disk.  The SOPS recipient checks read
    unencrypted metadata rather than performing live decryption, but a managed
    private SSH key is probed directly for validity, so an unparsable key fails
    here exactly as it does on the POSIX host.

    ConvertFrom-SshEd25519PublicKeyToAgePubKey is provided by
    convert-sshpublickeytoage.ps1, which apply.ps1 dot-sources before this file
    (alphabetical order so 'c' < 'i').

.NOTES
    Environment variables: (none)
    Exit codes: N/A — library script; functions use throw on failure.
#>

function Test-ManagedSshPrivateKey {
  <#
  .SYNOPSIS
    Probe one managed SSH private key for validity.

  .DESCRIPTION
    A file that exists is not a key that works.  An unparsable private key makes ssh
    report "invalid format" and fall back to no authentication, and a running agent
    hides that by answering first.

    Validity means OpenSSH can read the file as a private key, and a
    passphrase-protected key is valid.  ssh-keygen -l reads the cleartext public-key
    blob out of the openssh-key-v1 container, so it succeeds with or without a
    passphrase, never prompts, and never reads stdin.

    -l also accepts a bare .pub public key file, so the first line is required to
    carry a private-key PEM header.  The two checks together are what separates a
    private key from a public one; either alone would let the wrong file through.

    The probe runs through a symlink under a private temp directory.  Given the
    managed key path itself, -l prefers the sibling <key>.pub and reports THAT
    key's fingerprint without opening the private key, which would turn this into
    a check that passes a corrupt private key.  The symlink has no sibling to be
    picked up, and it never copies key material.

    Accepted limit: -l validates the container and the embedded public key, not the
    ciphertext.  A key whose private bytes are corrupt or truncated still reports a
    fingerprint.  Detecting that needs the passphrase, which this probe does not have
    and must never be given, so corruption surfaces at first use rather than here.

    Mirrors the probe in src/scripts/secrets/verify-secret-decryption.sh.  The two hosts
    must agree on whether the same managed key is acceptable.

  .PARAMETER SshKeygenExe
    Absolute path to the ssh-keygen executable.

  .PARAMETER PrivateKeyPath
    Absolute path to the managed SSH private key to probe.

  .PARAMETER TimeoutSeconds
    Upper bound on how long ssh-keygen may run before the probe gives up.  Exceeding
    it throws rather than hanging activation.

  .OUTPUTS
    None.  Throws naming the offending file when the key is not a valid OpenSSH
    private key, so the failure is attributable to one key.
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)]
    [string]$SshKeygenExe,

    [Parameter(Mandatory = $true)]
    [string]$PrivateKeyPath,

    [Parameter(Mandatory = $false)]
    [int]$TimeoutSeconds = 15
  )

  # A double quote in the path would be parsed as an argument separator below, silently
  # probing some other file instead of the one the manifest named.  Refuse it loudly.
  if ($PrivateKeyPath.Contains('"')) {
    throw "verification: ERROR — managed SSH private key path '$PrivateKeyPath' contains a double quote, which cannot be passed to ssh-keygen safely."
  }

  # -l reports a fingerprint for a bare .pub file as readily as for a private key,
  # so the header is what proves this file holds private key material.  Read it
  # directly rather than through ssh-keygen: a file that is not there, or not
  # readable, has to be rejected by name either way, and Test-Path would report a
  # directory as present.
  $privateKeyHeader = '^\-\-\-\-\-BEGIN [A-Z0-9 ]*PRIVATE KEY\-\-\-\-\-$'
  if (-not (Test-Path -LiteralPath $PrivateKeyPath -PathType Leaf)) {
    throw "verification: ERROR — managed SSH private key at '$PrivateKeyPath' does not exist or is not a regular file; fix the SOPS value or re-run the secret materialization."
  }
  $keyHeaderLine = Get-Content -LiteralPath $PrivateKeyPath -TotalCount 1 -ErrorAction Stop
  if ($keyHeaderLine -cnotmatch $privateKeyHeader) {
    throw "verification: ERROR — managed SSH private key at '$PrivateKeyPath' does not start with an OpenSSH private key header (found: '$keyHeaderLine'); ssh-keygen -l would accept a public key file here, so this is rejected before the probe. Fix the SOPS value or re-run the secret materialization."
  }

  # Probe through a symlink in a private temp directory.  Given the managed key
  # path directly, ssh-keygen -l prefers the sibling <key>.pub when one exists and
  # reports THAT key's fingerprint without ever opening the private key, so a
  # corrupt private key beside a valid .pub would read as fine.  Windows
  # materializes the pair the same way POSIX does, so the shadowing applies here
  # too.  A symlink carries no second copy of the key material.
  $probeDir = Join-Path ([IO.Path]::GetTempPath()) ("nucleus-key-probe-" + [guid]::NewGuid())
  New-Item -ItemType Directory -Path $probeDir -Force > $null
  $probeLink = Join-Path $probeDir 'key'
  try {
    New-Item -ItemType SymbolicLink -Path $probeLink -Target $PrivateKeyPath -ErrorAction Stop > $null
  }
  catch {
    Remove-Item -LiteralPath $probeDir -Recurse -Force -ErrorAction SilentlyContinue
    throw "verification: ERROR — could not stage managed SSH private key '$PrivateKeyPath' for probing: $($_.Exception.Message)"
  }

  try {
    $probeArguments = '-l -f "' + $probeLink + '"'

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $SshKeygenExe
    $startInfo.Arguments = $probeArguments
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true

    $probe = [System.Diagnostics.Process]::Start($startInfo)
    if ($null -eq $probe) {
      throw "verification: ERROR — could not start ssh-keygen to probe managed SSH private key '$PrivateKeyPath'."
    }

    # Close stdin before waiting, so nothing the probe writes can stall on an unanswered read.
    $probe.StandardInput.Close()

    # Drain both pipes concurrently.  Reading them only after the wait would deadlock on a
    # full pipe buffer, because the child blocks writing while the parent blocks waiting.
    $stdout = $probe.StandardOutput.ReadToEndAsync()
    $stderr = $probe.StandardError.ReadToEndAsync()

    if (-not $probe.WaitForExit($TimeoutSeconds * 1000)) {
      $probe.Kill()
      throw "verification: ERROR — ssh-keygen did not exit within $TimeoutSeconds s while probing managed SSH private key '$PrivateKeyPath'; refusing to continue, because an unbounded wait would stall apply."
    }
    # The bounded overload can return while the redirected pipes are still draining; the
    # parameterless overload waits for them to reach EOF.
    $probe.WaitForExit()

    # ssh-keygen -l exits non-zero for a malformed or unreadable key.  Only stdout is
    # consulted, so the failure is decided by an empty fingerprint line rather than by
    # the exit code, exactly as the POSIX probe does.
    $keyFingerprint = $stdout.Result
    if ([string]::IsNullOrWhiteSpace($keyFingerprint)) {
      $probeDiagnostic = $stderr.Result.Trim()
      if ([string]::IsNullOrWhiteSpace($probeDiagnostic)) {
        $probeDiagnostic = 'ssh-keygen wrote no diagnostic to stderr'
      }
      throw "verification: ERROR — managed SSH private key at '$PrivateKeyPath' is not a valid OpenSSH private key (ssh-keygen -l reported no fingerprint, so OpenSSH cannot read it): $probeDiagnostic; fix the SOPS value or re-run the secret materialization."
    }
  }
  finally {
    # The temp directory holds only the symlink, never key material.
    Remove-Item -LiteralPath $probeDir -Recurse -Force -ErrorAction SilentlyContinue
  }
}

function Invoke-SecretVerification {
  <#
  .SYNOPSIS
    Post-apply health check that verifies all SOPS files are decryptable by
    each registered backend.

  .DESCRIPTION
    Runs five checks in order, mirroring the POSIX verify-secret-decryption
    activation in src/modules/secrets.nix:

    1. Materialization sanity: managed SSH key files, git-identity env, and
       managed-key manifest files exist and are non-empty.  Every private key listed
       in managed-ssh-key-paths is then probed for validity: the file must carry an
       OpenSSH private key header, and ssh-keygen -l must read a fingerprint from it.
       A passphrase-protected key passes, because -l reads the cleartext public-key
       blob and never needs the passphrase; a malformed or public key file is
       rejected.  The probe closes its own stdin and bounds its wait so a wedged
       ssh-keygen cannot stall the run.
       Mirrors the POSIX verifier in src/scripts/secrets/verify-secret-decryption.sh.
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

  .PARAMETER SshKeygenExe
    Absolute path to the ssh-keygen executable, used to probe each managed SSH
    private key for validity.

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
      -SshKeygenExe 'C:\Windows\System32\OpenSSH\ssh-keygen.exe' `
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
    [string]$SshKeygenExe,

    [Parameter(Mandatory = $true)]
    [string]$HostKeyPath,

    [Parameter(Mandatory = $true)]
    [string]$Username,

    [Parameter(Mandatory = $true)]
    [string]$SecretsDir,

    [Parameter(Mandatory = $true)]
    [string]$RepoRoot
  )

  Write-NucleusInfo -CommandName 'verification' "running post-apply secret verification..."

  $userHome = Resolve-SecretUserHomedir -Username $Username
  if ([string]::IsNullOrWhiteSpace($userHome)) {
    throw "verification: ERROR — could not resolve home directory for user '$Username'."
  }

  $configDir = Join-Path -Path $userHome -ChildPath 'AppData\Local\nucleus'
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
    $wallpaperSopsFiles = @(Get-ChildItem -Path $usersRoot -Recurse -Filter '*.sops' -File -ErrorAction SilentlyContinue |  # check-suppress:suppression_doc: probe -- users dir may hold no .sops files; Count guard below handles absence
      Where-Object { $_.FullName -match '[\\/]wallpapers[\\/]encrypted[\\/]' })
    if ($wallpaperSopsFiles.Count -gt 0) {
      $sopsTestFiles += @($wallpaperSopsFiles | Select-Object -ExpandProperty FullName)
    }
  }

  # -------------------------------------------------------------------------
  # 1. Materialization sanity: key files must exist and be non-empty, and every
  # managed SSH private key must be a valid OpenSSH private key.
  # -------------------------------------------------------------------------
  Write-NucleusInfo -CommandName 'verification' "[1/5] checking secret materialization..."
  $sanityPaths = @($sshKeyPath, $sshPublicKeyPath, $managedGpgKeysManifest, $managedSshKeysManifest, $managedSshKeyPathsManifest, $gitIdentityPath)
  foreach ($sanityPath in $sanityPaths) {
    if (-not (Test-Path -Path $sanityPath) -or (Get-Item -Path $sanityPath).Length -eq 0) {
      throw "verification: ERROR — managed secret artefact missing or empty: $sanityPath"
    }
  }

  # Existence is not validity.  The manifest enumerates every managed private key,
  # including the personal one checked above, and each is probed so a failure names
  # the offending key file rather than the manifest as a whole.
  foreach ($managedKeyLine in (Get-Content -LiteralPath $managedSshKeyPathsManifest)) {
    $managedKeyPath = $managedKeyLine.Trim()
    if ([string]::IsNullOrWhiteSpace($managedKeyPath)) {
      continue
    }
    if (-not (Test-Path -LiteralPath $managedKeyPath -PathType Leaf) -or (Get-Item -LiteralPath $managedKeyPath).Length -eq 0) {
      throw "verification: ERROR — managed SSH private key missing or empty: $managedKeyPath"
    }
    Test-ManagedSshPrivateKey -SshKeygenExe $SshKeygenExe -PrivateKeyPath $managedKeyPath
  }
  Write-NucleusInfo -CommandName 'verification' "[1/5] materialization sanity: OK"

  # -------------------------------------------------------------------------
  # 2. GPG key presence: the managed fingerprint must be in the keyring.
  # -------------------------------------------------------------------------
  Write-NucleusInfo -CommandName 'verification' "[2/5] checking GPG key presence..."
  $managedFpr = (Get-Content -Path $managedGpgKeysManifest -Raw).Trim()
  if ([string]::IsNullOrWhiteSpace($managedFpr)) {
    throw "verification: ERROR — managed-gpg-keys manifest is empty; gpg-import may have failed."
  }
  $allSecretKeysFpr = (& $GpgExe --with-colons --no-autostart --list-secret-keys 2>&1) -join "`n"
  if (-not ($allSecretKeysFpr -like "*$managedFpr*")) {
    throw "verification: ERROR — managed GPG key $managedFpr not in keyring after materialization."
  }
  Write-NucleusInfo -CommandName 'verification' "[2/5] GPG key presence: OK ($managedFpr)"

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
  Write-NucleusInfo -CommandName 'verification' "[3/5] checking GPG recipient registration in all SOPS files..."
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
  Write-NucleusInfo -CommandName 'verification' "[3/5] GPG SOPS recipient check: OK"

  # -------------------------------------------------------------------------
  # 4. Personal SSH age recipient check for all SOPS files.
  # Derive the age public key from the managed SSH public key file (passphrase-
  # free; the public key carries no secret material) and search each SOPS
  # file's plaintext sops.age[] metadata for the derived key value.
  # YAML SOPS files store the key as "recipient: age1..." (unquoted); binary
  # SOPS files (e.g. wallpaper blobs) use JSON format with both the key name
  # and value double-quoted.  Searching for the bare age key value handles both.
  # -------------------------------------------------------------------------
  Write-NucleusInfo -CommandName 'verification' "[4/5] checking personal SSH age recipient registration in all SOPS files..."
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
  Write-NucleusInfo -CommandName 'verification' "[4/5] SSH age SOPS recipient check: OK ($sshAgePub)"

  # -------------------------------------------------------------------------
  # 5. Machine SSH host key existence check (advisory warning only).
  # -------------------------------------------------------------------------
  Write-NucleusInfo -CommandName 'verification' "[5/5] checking machine SSH host key..."
  if (-not (Test-Path -Path $HostKeyPath)) {
    Write-NucleusWarning -CommandName 'verification' "$HostKeyPath missing; this machine cannot be the primary SOPS age recipient until the host key is registered in .sops.yaml."
  }
  else {
    Write-NucleusInfo -CommandName 'verification' "[5/5] machine SSH host key: present ($HostKeyPath)"
  }

  Write-NucleusInfo -CommandName 'verification' "post-apply secret verification passed."
}
