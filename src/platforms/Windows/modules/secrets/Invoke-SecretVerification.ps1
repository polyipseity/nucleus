<#
.SYNOPSIS
    Post-apply secret health check for SOPS file recipient verification.

.DESCRIPTION
    Mirrors the POSIX verify-secret-decryption Home Manager activation in secrets.nix.
    Verifies that all SOPS files have the correct recipients registered and that
    managed secret artefacts are present on disk.  The SOPS recipient checks read
    unencrypted metadata rather than performing live decryption, but a managed
    private SSH key is probed directly for unattended usability, so a
    passphrase-protected key fails here exactly as it does on the POSIX host.

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
    Probe one managed SSH private key for unattended usability.

  .DESCRIPTION
    A file that exists is not a key that works.  An unparsable private key makes ssh
    report "invalid format" and fall back to no authentication, and a running agent
    hides that by answering first.  Derive the public half to prove OpenSSH can read
    the file.  -y derives from the PRIVATE key and an empty -P makes the derivation
    fail for a passphrase-protected key, because the supplied passphrase is wrong.

    -e is deliberately not used: it reads the unencrypted header of the
    openssh-key-v1 format, which a protected key still has, so it accepted every
    protected key.

    This probe cannot answer an interactive prompt, and that is enforced rather than
    assumed: standard input is closed as soon as the probe starts, so a passphrase
    prompt takes EOF and exits non-zero instead of blocking, and the wait is bounded
    so a wedged process cannot stall apply.  A key an operator could unlock by typing
    the passphrase is therefore still rejected, which is the whole point -- a managed
    key has to work unattended.

    Mirrors the probe in src/scripts/secrets/verify-secret-decryption.sh, which closes
    stdin with </dev/null for the same reason.  The two hosts must agree on whether
    the same managed key is acceptable.

  .PARAMETER SshKeygenExe
    Absolute path to the ssh-keygen executable.

  .PARAMETER PrivateKeyPath
    Absolute path to the managed SSH private key to probe.

  .PARAMETER TimeoutSeconds
    Upper bound on how long ssh-keygen may run before the probe gives up.  Exceeding
    it throws rather than hanging activation.

  .OUTPUTS
    None.  Throws naming the offending file when the key cannot be read with an
    empty passphrase, so the failure is attributable to one key.
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

  # The empty passphrase is encoded as "" INSIDE an argument string rather than passed
  # as a PowerShell value.  Windows PowerShell 5.1 is a live path here: apply.ps1 has no
  # #Requires -Version and re-elevates into the caller's host, and 5.1's native-argument
  # binder can drop or collapse a separate empty-string argument.  Either outcome loses
  # -P entirely, and a lost -P turns a rejection into a prompt.
  #   -P ""   is the empty argument under both 5.1 and 7 when it appears in this string.
  #   -P ''   and -P $var are the same single empty argument either way, so neither is
  #           any safer; only the comment claiming otherwise was wrong.
  #   '""' as a VALUE is wrong: empty on 5.1, but two quote characters on 7, which would
  #     false-reject an unencrypted key.
  #   Start-Process -ArgumentList cannot express this -- it joins on spaces and drops the
  #     empty element.  --% cannot take a variable.
  $probeArguments = '-y -P "" -f "' + $PrivateKeyPath + '"'

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

  # Close stdin before waiting.  This, not the argument spelling, is what makes a
  # passphrase prompt impossible to answer.
  $probe.StandardInput.Close()

  # Drain both pipes concurrently.  Reading them only after the wait would deadlock on a
  # full pipe buffer, because the child blocks writing while the parent blocks waiting.
  $stdout = $probe.StandardOutput.ReadToEndAsync()
  $stderr = $probe.StandardError.ReadToEndAsync()

  if (-not $probe.WaitForExit($TimeoutSeconds * 1000)) {
    $probe.Kill()
    throw "verification: ERROR — ssh-keygen did not exit within $TimeoutSeconds s while probing managed SSH private key '$PrivateKeyPath'; refusing to continue, because an unanswered prompt would otherwise stall apply."
  }
  # The bounded overload can return while the redirected pipes are still draining; the
  # parameterless overload waits for them to reach EOF.
  $probe.WaitForExit()

  # ssh-keygen -y exits non-zero for a malformed, unreadable, or passphrase-protected
  # key.  Only stdout is consulted, so the failure is decided by an empty derivation
  # rather than by the exit code, exactly as the POSIX probe does.
  $derivedPublicKey = $stdout.Result
  if ([string]::IsNullOrWhiteSpace($derivedPublicKey)) {
    $probeDiagnostic = $stderr.Result.Trim()
    if ([string]::IsNullOrWhiteSpace($probeDiagnostic)) {
      $probeDiagnostic = 'ssh-keygen wrote no diagnostic to stderr'
    }
    throw "verification: ERROR — managed SSH private key at '$PrivateKeyPath' is not a usable OpenSSH private key (ssh-keygen -y derived no public key, so it is unreadable or passphrase-protected): $probeDiagnostic; fix the SOPS value or re-run the secret materialization."
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
       in managed-ssh-key-paths is then probed with ssh-keygen -y and an empty
       passphrase, so a key that cannot be read unattended -- malformed or
       passphrase-protected -- is rejected rather than passing an existence check.
       The probe closes its own stdin and bounds its wait, so a key that would
       otherwise prompt is rejected instead of stalling the run.
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
    private key for unattended usability.

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
  # managed SSH private key must be readable with an empty passphrase.
  # -------------------------------------------------------------------------
  Write-NucleusInfo -CommandName 'verification' "[1/5] checking secret materialization..."
  $sanityPaths = @($sshKeyPath, $sshPublicKeyPath, $managedGpgKeysManifest, $managedSshKeysManifest, $managedSshKeyPathsManifest, $gitIdentityPath)
  foreach ($sanityPath in $sanityPaths) {
    if (-not (Test-Path -Path $sanityPath) -or (Get-Item -Path $sanityPath).Length -eq 0) {
      throw "verification: ERROR — managed secret artefact missing or empty: $sanityPath"
    }
  }

  # Existence is not usability.  The manifest enumerates every managed private key,
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
