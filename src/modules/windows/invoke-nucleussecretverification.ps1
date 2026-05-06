# modules/windows/invoke-nucleussecretverification.ps1 — Post-apply secret health check.
#
# Mirrors the POSIX verifySecretDecryption Home Manager activation in secrets.nix.
# Verifies that all SOPS files have the correct recipients registered and that
# managed secret artefacts are present on disk.  Uses metadata inspection rather
# than live decryption so passphrase-protected keys do not cause false failures.

function ConvertFrom-SshEd25519PublicKeyToAgePubKey {
  <#
  .SYNOPSIS
    Converts an SSH Ed25519 public key to an age bech32 public key.

  .DESCRIPTION
    Parses the SSH wire format (RFC 4253) to extract the raw 32-byte Ed25519
    public key, converts it from the Edwards curve representation to the
    Montgomery/X25519 form used by age (birational map u = (1+y)/(1-y) mod p),
    then bech32-encodes the result with HRP "age".

    Uses System.Numerics.BigInteger for the 255-bit field arithmetic and [long]
    arithmetic for the bech32 bit-conversion loop to avoid overflow.

    This mirrors the `ssh-to-age -i <pubkey.pub>` conversion used on POSIX hosts
    to derive age public keys from SSH public keys without accessing any
    passphrase-protected private key material.  No external tool is required.

  .PARAMETER SshPublicKeyLine
    Full SSH public key line in OpenSSH authorized_keys format,
    e.g. "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5... optional-comment".

  .OUTPUTS
    [string] bech32-encoded age public key, e.g. "age1...".

  .EXAMPLE
    ConvertFrom-SshEd25519PublicKeyToAgePubKey "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5..."
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)]
    [string]$SshPublicKeyLine
  )

  # Extract key type and base64 blob (space-separated fields in OpenSSH format).
  $parts = $SshPublicKeyLine.Trim() -split '\s+'
  if ($parts.Length -lt 2 -or $parts[0] -ne 'ssh-ed25519') {
    throw "ConvertFrom-SshEd25519PublicKeyToAgePubKey: input must be an ssh-ed25519 public key line; got '$($parts[0])'."
  }
  [byte[]]$blob = [System.Convert]::FromBase64String($parts[1])

  # SSH wire format (RFC 4253): uint32 name-len + name-bytes + uint32 key-len + key-bytes.
  # Read the algorithm name length (big-endian uint32) and skip past it.
  [long]$nameLen = ([long]$blob[0] -shl 24) -bor ([long]$blob[1] -shl 16) -bor `
                   ([long]$blob[2] -shl 8) -bor [long]$blob[3]
  [int]$offset = 4 + [int]$nameLen

  # Read the key data length (big-endian uint32); must be 32 for Ed25519.
  [long]$keyLen = ([long]$blob[$offset] -shl 24) -bor ([long]$blob[$offset + 1] -shl 16) -bor `
                  ([long]$blob[$offset + 2] -shl 8) -bor [long]$blob[$offset + 3]
  $offset += 4
  if ($keyLen -ne 32) {
    throw "ConvertFrom-SshEd25519PublicKeyToAgePubKey: expected 32-byte Ed25519 key, got $keyLen bytes."
  }
  [byte[]]$ed25519Key = $blob[$offset..($offset + 31)]

  # Convert Ed25519 (Edwards curve) public key to X25519 (Montgomery curve) public key.
  # Ed25519 key bytes: 32-byte little-endian y-coordinate; bit 255 (high bit of byte[31])
  # carries the sign of the x-coordinate and is cleared before reading y.
  # Birational map: u = (1 + y) / (1 - y) mod p, p = 2^255 - 19.
  # This is the same computation that `ssh-to-age -i` performs internally.
  [byte[]]$yBytes = $ed25519Key.Clone()
  $yBytes[31] = $yBytes[31] -band 0x7f  # clear x-sign bit; only y is needed

  # Append a 0x00 byte so BigInteger treats the little-endian buffer as non-negative.
  [byte[]]$yBuf = New-Object byte[] 33
  [Array]::Copy($yBytes, $yBuf, 32)
  $y = [System.Numerics.BigInteger]::new($yBuf)

  # p = 2^255 - 19 (the shared prime for Curve25519 / Ed25519).
  $two = [System.Numerics.BigInteger]::new(2)
  $p = [System.Numerics.BigInteger]::Pow($two, 255) - [System.Numerics.BigInteger]::new(19)
  $one = [System.Numerics.BigInteger]::One

  # u = (1 + y) * inv(1 - y) mod p.  Use (p + 1 - y) to keep the denominator positive.
  $num      = ($one + $y) % $p
  $denom    = ($p + $one - $y) % $p
  # Modular inverse via Fermat's little theorem: inv(a) = a^(p-2) mod p (p is prime).
  $denomInv = [System.Numerics.BigInteger]::ModPow($denom, $p - $two, $p)
  $u        = ($num * $denomInv) % $p

  # Encode u as 32 bytes little-endian (the X25519 / age public key).
  # ToByteArray() may omit leading zero bytes or append a sign byte; normalise to 32 bytes.
  [byte[]]$uRaw = $u.ToByteArray()
  [byte[]]$x25519Key = New-Object byte[] 32
  [Array]::Copy($uRaw, $x25519Key, [Math]::Min($uRaw.Length, 32))

  # Convert 32 bytes (8-bit groups) to 5-bit groups for the bech32 data field.
  # Implements convertbits(data, 8, 5, pad=True) from BIP-0173.  We accumulate
  # up to 13 bits at a time (8 new + at most 4 carried) and mask to 13 bits to
  # keep arithmetic in range for [long] without overflow risk.
  $data5 = [System.Collections.Generic.List[int]]::new()
  [long]$acc = 0
  [int]$bits = 0
  foreach ($byte in $x25519Key) {
    $acc = (($acc -shl 8) -bor [long]$byte) -band 0x1fff
    $bits += 8
    while ($bits -ge 5) {
      $bits -= 5
      $data5.Add([int](($acc -shr $bits) -band 0x1f))
    }
  }
  # Emit remaining bits zero-padded to fill the final 5-bit group.
  if ($bits -gt 0) {
    $data5.Add([int](($acc -shl (5 - $bits)) -band 0x1f))
  }

  # Compute the bech32 checksum over hrpExpand("age") + data5 + [0,0,0,0,0,0].
  # GF(2^30) generator coefficients from BIP-0173 (also used by the age spec).
  $GEN = [long[]]@(0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3)
  $hrp = 'age'

  # hrpExpand: high 3 bits of each HRP character, a zero separator, then the
  # low 5 bits of each character.  This is the standard bech32 domain separation.
  $polyInput = [System.Collections.Generic.List[int]]::new()
  foreach ($ch in $hrp.ToCharArray()) { $polyInput.Add(([int][char]$ch) -shr 5) }
  $polyInput.Add(0)
  foreach ($ch in $hrp.ToCharArray()) { $polyInput.Add(([int][char]$ch) -band 31) }
  foreach ($v in $data5) { $polyInput.Add($v) }
  # Six zero-value placeholders; the actual checksum is computed to make these
  # satisfy the polynomial congruence.
  for ($i = 0; $i -lt 6; $i++) { $polyInput.Add(0) }

  # Polynomial modulus over GF(2^30).  [long] used throughout to prevent the
  # 30-bit intermediate XOR values from being sign-extended by PowerShell's
  # arithmetic right-shift on negative [int] operands.
  [long]$c = 1
  foreach ($v in $polyInput) {
    [int]$c0 = [int](($c -shr 25) -band 0x1f)
    $c = (($c -band 0x1ffffff) -shl 5) -bxor [long]$v
    for ($i = 0; $i -lt 5; $i++) {
      if (($c0 -shr $i) -band 1) { $c = $c -bxor $GEN[$i] }
    }
  }
  [long]$polymod = $c -bxor 1

  # Extract 6 checksum 5-bit values from the 30-bit polymod, most-significant
  # group first (i=5 gives bits 29-25; i=0 gives bits 4-0).
  $checksum = for ($i = 5; $i -ge 0; $i--) { [int](($polymod -shr (5 * $i)) -band 0x1f) }

  # Assemble the final bech32 string: HRP + "1" + encoded(data5 + checksum).
  $charset = 'qpzry9x8gf2tvdw0s3jn54khce6mua7l'
  $sb = [System.Text.StringBuilder]::new()
  $null = $sb.Append($hrp + '1')
  foreach ($v in $data5) { $null = $sb.Append($charset[$v]) }
  foreach ($v in $checksum) { $null = $sb.Append($charset[$v]) }
  return $sb.ToString()
}

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

  .PARAMETER PrimaryUsername
    Canonical primary username whose materialized files are inspected.

  .PARAMETER SecretsDir
    Absolute path to the directory containing the SOPS secret YAML files
    (src/secrets).

  .PARAMETER WallpaperAssetsDir
    Absolute path to the directory containing wallpaper SOPS blobs
    (src/assets/wallpapers).

  .EXAMPLE
    Invoke-NucleusSecretVerification `
      -GpgExe 'C:\Program Files\GnuPG\bin\gpg.exe' `
      -HostKeyPath 'C:\ProgramData\ssh\ssh_host_ed25519_key' `
      -PrimaryUsername 'polyipseity' `
      -SecretsDir '.\src\secrets' `
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
    [string]$SecretsDir,

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
  # Dump all secret-key fingerprints once with --with-colons (machine-readable,
  # non-interactive) and --no-autostart (prevents launching a new agent daemon,
  # which can deadlock if the agent socket is not yet ready).  Cache the output
  # for reuse in check 3 to avoid repeated invocations with per-file arguments.
  $allSecretKeysFpr = (& $GpgExe --with-colons --no-autostart --list-secret-keys 2>&1) -join "`n"
  if (-not ($allSecretKeysFpr -like "*$managedFpr*")) {
    throw "nucleus: ERROR — managed GPG key $managedFpr not in keyring after materialization."
  }
  Write-Host "nucleus: [2/5] GPG key presence: OK ($managedFpr)" -ForegroundColor Green

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
  Write-Host "nucleus: [3/5] checking GPG recipient registration in all SOPS files..." -ForegroundColor Gray
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
    throw "nucleus: ERROR — GPG SOPS decryption check failed for: $($gpgFailures -join ', '); managed GPG key may not be registered in .sops.yaml."
  }
  Write-Host "nucleus: [3/5] GPG SOPS recipient check: OK" -ForegroundColor Green

  # -------------------------------------------------------------------------
  # 4. Personal SSH age recipient check for all SOPS files.
  # Derive the age public key from the managed SSH public key file (passphrase-
  # free; the public key carries no secret material) and search each SOPS
  # file's plaintext sops.age[] metadata for the derived key value.
  # YAML SOPS files store the key as "recipient: age1..." (unquoted); binary
  # SOPS files (e.g. wallpaper blobs) use JSON format with both the key name
  # and value double-quoted.  Searching for the bare age key value handles both.
  # -------------------------------------------------------------------------
  Write-Host "nucleus: [4/5] checking personal SSH age recipient registration in all SOPS files..." -ForegroundColor Gray
  if (-not (Test-Path -Path $sshPublicKeyPath)) {
    throw "nucleus: ERROR — managed personal SSH public key not found at $sshPublicKeyPath; cannot derive age public key for recipient check."
  }
  $sshPubKeyLine = (Get-Content -Path $sshPublicKeyPath -Raw).Trim()
  $sshAgePub = ConvertFrom-SshEd25519PublicKeyToAgePubKey -SshPublicKeyLine $sshPubKeyLine
  $sshFailures = @()
  foreach ($sopsFile in $sopsTestFiles) {
    # Search for the bare age key value (not "recipient: KEY") so both YAML
    # (unquoted field) and JSON (double-quoted key and value) SOPS formats
    # are handled without needing two separate search patterns.
    $hasSshRecipient = Select-String -Path $sopsFile -Pattern $sshAgePub -SimpleMatch -Quiet -ErrorAction SilentlyContinue
    if (-not $hasSshRecipient) {
      $sshFailures += [System.IO.Path]::GetFileName($sopsFile)
    }
  }
  if ($sshFailures.Count -gt 0) {
    throw "nucleus: ERROR — personal SSH key age-backend SOPS decryption check failed for: $($sshFailures -join ', '); SSH key may not be registered in .sops.yaml as an age recipient."
  }
  Write-Host "nucleus: [4/5] SSH age SOPS recipient check: OK ($sshAgePub)" -ForegroundColor Green

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
