# modules/windows/convert-sshpublickeytoage.ps1 — SSH Ed25519 to age public key conversion.
#
# Provides ConvertFrom-SshEd25519PublicKeyToAgePubKey, a pure-PowerShell
# implementation of the ssh-to-age public-key conversion path.  Used by both
# invoke-nucleussecretverification.ps1 (SOPS recipient checks) and
# register-nucleushostagekey.ps1 (machine age key auto-registration) so a
# single authoritative implementation is shared across both call sites.

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
