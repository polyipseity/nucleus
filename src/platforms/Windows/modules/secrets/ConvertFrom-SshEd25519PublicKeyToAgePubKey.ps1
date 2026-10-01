<#
.SYNOPSIS
    SSH Ed25519 to age public key conversion for SOPS age recipient management.

.DESCRIPTION
    Pure-PowerShell equivalent of `ssh-to-age -i`, shared by
    Invoke-SecretVerification.ps1 and Register-HostAgeKey.ps1. Throws on failure.

.NOTES
    Environment variables: (none)
#>

function ConvertFrom-SshEd25519PublicKeyToAgePubKey {
  <#
  .SYNOPSIS
    Converts an SSH Ed25519 public key to an age bech32 public key.

  .DESCRIPTION
    Parses the SSH wire format (RFC 4253), maps the Edwards key to the
    Montgomery/X25519 form age uses (u = (1+y)/(1-y) mod p), then bech32-encodes
    it with HRP "age". Uses BigInteger for the field arithmetic and [long] for
    the bit conversion, which would overflow otherwise.

  .PARAMETER SshPublicKeyLine
    Full SSH public key line, e.g. "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5... optional-comment".

  .OUTPUTS
    [string] bech32-encoded age public key, e.g. "age1...".
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

  # Skip the algorithm name: uint32 name-len + name-bytes (RFC 4253).
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

  # Ed25519 to X25519 via the birational map u = (1 + y) / (1 - y) mod p.
  # Only y is needed, so clear the x-sign bit (high bit of byte[31]) first.
  [byte[]]$yBytes = $ed25519Key.Clone()
  $yBytes[31] = $yBytes[31] -band 0x7f  # clear x-sign bit; only y is needed

  # The 0x00 byte keeps BigInteger from reading the buffer as negative.
  [byte[]]$yBuf = New-Object byte[] 33
  [Array]::Copy($yBytes, $yBuf, 32)
  $y = [System.Numerics.BigInteger]::new($yBuf)

  $two = [System.Numerics.BigInteger]::new(2)
  $p = [System.Numerics.BigInteger]::Pow($two, 255) - [System.Numerics.BigInteger]::new(19)
  $one = [System.Numerics.BigInteger]::One

  # p + 1 - y keeps the denominator positive. Fermat: inv(a) = a^(p-2) mod p.
  $num      = ($one + $y) % $p
  $denom    = ($p + $one - $y) % $p
  $denomInv = [System.Numerics.BigInteger]::ModPow($denom, $p - $two, $p)
  $u        = ($num * $denomInv) % $p

  # ToByteArray() drops leading zero bytes and can append a sign byte, so normalise to 32.
  [byte[]]$uRaw = $u.ToByteArray()
  [byte[]]$x25519Key = New-Object byte[] 32
  [Array]::Copy($uRaw, $x25519Key, [Math]::Min($uRaw.Length, 32))

  # convertbits(data, 8, 5, pad=True) from BIP-0173. Masking to 13 bits keeps the
  # accumulator in range for [long].
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

  # 6 checksum values from the 30-bit polymod, most-significant group first.
  $checksum = for ($i = 5; $i -ge 0; $i--) { [int](($polymod -shr (5 * $i)) -band 0x1f) }

  $charset = 'qpzry9x8gf2tvdw0s3jn54khce6mua7l'
  $sb = [System.Text.StringBuilder]::new()
  $null = $sb.Append($hrp + '1')  # check-suppress:suppression_doc: Append returns StringBuilder, discarded
  foreach ($v in $data5) {
      $null = $sb.Append($charset[$v]) }  # check-suppress:suppression_doc: Append returns StringBuilder, discarded
  foreach ($v in $checksum) {
      $null = $sb.Append($charset[$v]) }  # check-suppress:suppression_doc: Append returns StringBuilder, discarded
  return $sb.ToString()
}
