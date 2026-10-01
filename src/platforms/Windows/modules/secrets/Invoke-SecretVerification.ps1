<#
.SYNOPSIS
    Post-apply secret health check for SOPS file recipient verification.

.DESCRIPTION
    Mirrors the POSIX verify-secret-decryption activation in secrets.nix. SOPS
    recipient checks read unencrypted metadata, but a managed private SSH key is
    probed directly, so an unparsable key fails here as it does on POSIX.

    ConvertFrom-SshEd25519PublicKeyToAgePubKey is provided by
    convert-sshpublickeytoage.ps1, which apply.ps1 dot-sources before this file.
#>

function Test-ManagedSshPrivateKey {
  <#
  .SYNOPSIS
    Probe one managed SSH private key for validity.

  .DESCRIPTION
    A file that exists is not a key that works: an unparsable private key makes
    ssh report "invalid format" and fall back to no authentication, and a running
    agent hides that by answering first.

    Validity means OpenSSH can read the file, and a passphrase-protected key is
    valid. ssh-keygen -l reads the cleartext public-key blob out of the
    openssh-key-v1 container, so it succeeds with or without a passphrase, never
    prompts, and never reads stdin. -l also accepts a bare .pub file, so the
    header check is what separates a private key from a public one.

    The probe runs through a symlink under a private temp directory: given the
    managed key path, -l prefers the sibling <key>.pub and reports THAT key's
    fingerprint without opening the private key. The symlink has no sibling to be
    picked up and never copies key material.

    Accepted limit: -l validates the container and the embedded public key, not
    the ciphertext, and detecting ciphertext corruption needs the passphrase this
    probe must never be given. Corruption surfaces at first use.

    Mirrors src/scripts/secrets/verify-secret-decryption.sh so both hosts agree on
    whether the same managed key is acceptable.

  .PARAMETER TimeoutSeconds
    Upper bound on how long ssh-keygen may run. Exceeding it throws rather than
    hanging activation.

  .OUTPUTS
    None. Throws naming the offending file, so the failure is attributable.
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

  # A double quote in the path would parse as an argument separator, probing some
  # other file. Refuse it loudly.
  if ($PrivateKeyPath.Contains('"')) {
    throw "verification: ERROR — managed SSH private key path '$PrivateKeyPath' contains a double quote, which cannot be passed to ssh-keygen safely."
  }

  # WHY read the header here: -l accepts a bare .pub file as readily as a private
  # key, and an absent or unreadable file has to be rejected by name either way,
  # which Test-Path would not do for a directory.
  $privateKeyHeader = '^\-\-\-\-\-BEGIN [A-Z0-9 ]*PRIVATE KEY\-\-\-\-\-$'
  if (-not (Test-Path -LiteralPath $PrivateKeyPath -PathType Leaf)) {
    throw "verification: ERROR — managed SSH private key at '$PrivateKeyPath' does not exist or is not a regular file; fix the SOPS value or re-run the secret materialization."
  }
  $keyHeaderLine = Get-Content -LiteralPath $PrivateKeyPath -TotalCount 1 -ErrorAction Stop
  if ($keyHeaderLine -cnotmatch $privateKeyHeader) {
    throw "verification: ERROR — managed SSH private key at '$PrivateKeyPath' does not start with an OpenSSH private key header (found: '$keyHeaderLine'); ssh-keygen -l would accept a public key file here, so this is rejected before the probe. Fix the SOPS value or re-run the secret materialization."
  }

  # WHY the symlink: -l prefers the sibling <key>.pub and reports THAT
  # fingerprint without opening the private key, so a corrupt private key beside
  # a valid .pub would read as fine. Windows materializes the pair the same way.
  $probeDir = Join-Path ([IO.Path]::GetTempPath()) ("nucleus-key-probe-" + [guid]::NewGuid())
  New-Item -ItemType Directory -Path $probeDir -Force > $null
  $probeLink = Join-Path $probeDir 'key'
  try {
    New-Item -ItemType SymbolicLink -Path $probeLink -Target $PrivateKeyPath -ErrorAction Stop > $null
  }
  catch {
    Remove-Item -LiteralPath $probeDir -Recurse -Force -ErrorAction SilentlyContinue  # check-suppress:suppression_doc: staging already failed and the throw below reports it; a failed removal leaves an empty temp dir
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

    # Close stdin before waiting, so nothing the probe writes stalls on an unanswered read.
    $probe.StandardInput.Close()

    # WHY concurrently: reading after the wait deadlocks on a full pipe buffer.
    $stdout = $probe.StandardOutput.ReadToEndAsync()
    $stderr = $probe.StandardError.ReadToEndAsync()

    if (-not $probe.WaitForExit($TimeoutSeconds * 1000)) {
      $probe.Kill()
      throw "verification: ERROR — ssh-keygen did not exit within $TimeoutSeconds s while probing managed SSH private key '$PrivateKeyPath'; refusing to continue, because an unbounded wait would stall apply."
    }
    # The bounded overload can return while the pipes still drain; the parameterless
    # one waits for EOF.
    $probe.WaitForExit()

    # WHY stdout only: the exit code is not the signal, an empty fingerprint line
    # is, exactly as the POSIX probe does.
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
    Remove-Item -LiteralPath $probeDir -Recurse -Force -ErrorAction SilentlyContinue  # check-suppress:suppression_doc: the probe dir holds only a symlink, never key material; a failed removal leaks an empty temp dir
  }
}

function Invoke-SecretVerification {
  <#
  .SYNOPSIS
    Post-apply health check that verifies all SOPS files are decryptable by
    each registered backend.

  .DESCRIPTION
    Runs five checks in order, mirroring the POSIX verifier:

    1. Materialization sanity: managed key files, git-identity env and the
       managed-key manifests exist and are non-empty, and every key listed in
       managed-ssh-key-paths is probed. A passphrase-protected key passes.
    2. GPG key presence: the fingerprint in the managed-gpg-keys manifest is in
       the keyring.
    3. GPG SOPS recipient check on each SOPS file's unencrypted metadata,
       accumulating failures. Hard error: GPG is the last-resort global backup.
    4. Personal SSH age recipient check: the age key derived from the managed
       public SSH key must appear in each SOPS file. Hard error: it is the
       designated personal age recipient in .sops.yaml.
    5. Machine SSH host key existence: advisory only, because on first
       bootstrap the key may not be registered in .sops.yaml yet.
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

  # 1. Materialization sanity.
  Write-NucleusInfo -CommandName 'verification' "[1/5] checking secret materialization..."
  $sanityPaths = @($sshKeyPath, $sshPublicKeyPath, $managedGpgKeysManifest, $managedSshKeysManifest, $managedSshKeyPathsManifest, $gitIdentityPath)
  foreach ($sanityPath in $sanityPaths) {
    if (-not (Test-Path -Path $sanityPath) -or (Get-Item -Path $sanityPath).Length -eq 0) {
      throw "verification: ERROR — managed secret artefact missing or empty: $sanityPath"
    }
  }

  # WHY probe each key: existence is not validity, and probing names the
  # offending key file instead of the manifest as a whole.
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

  # 2. GPG key presence.
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

  # 3. GPG SOPS recipient check for all SOPS files.
  # WHY the subkey: SOPS records the encryption subkey fingerprint in fp:, and
  # comparing the primary fingerprint directly gives false failures when SOPS
  # chose a subkey. Together with check 2 this confirms GPG holds the private
  # key material.
  # WHY two formats: YAML SOPS files store fp unquoted and whitespace-prefixed,
  # binary blobs (wallpapers) store it JSON-quoted.
  Write-NucleusInfo -CommandName 'verification' "[3/5] checking GPG recipient registration in all SOPS files..."
  $gpgFailures = @()
  foreach ($sopsFile in $sopsTestFiles) {
    # WHY one regex: it matches both YAML (\s+fp:) and JSON ("fp":), and the hex
    # match extracts the fingerprint without a separate quote-stripping step.
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

  # 4. Personal SSH age recipient check for all SOPS files.
  # The age key is derived from the public key, so no passphrase is needed, and
  # searching for the bare value covers both the YAML and JSON encodings.
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

  # 5. Machine SSH host key existence, advisory only.
  Write-NucleusInfo -CommandName 'verification' "[5/5] checking machine SSH host key..."
  if (-not (Test-Path -Path $HostKeyPath)) {
    Write-NucleusWarning -CommandName 'verification' "$HostKeyPath missing; this machine cannot be the primary SOPS age recipient until the host key is registered in .sops.yaml."
  }
  else {
    Write-NucleusInfo -CommandName 'verification' "[5/5] machine SSH host key: present ($HostKeyPath)"
  }

  Write-NucleusInfo -CommandName 'verification' "post-apply secret verification passed."
}
