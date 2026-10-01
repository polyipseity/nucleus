<#
.SYNOPSIS
    Machine age key auto-registration for SOPS decryption on this host.

.DESCRIPTION
    Windows twin of register_host_age_key_if_needed in src/scripts/apply.sh.
    Throws on failure.

.NOTES
    Environment variables: (none)
#>

function Register-HostAgeKey {
  <#
  .SYNOPSIS
    Registers this machine's SSH host public key as an age recipient in
    .sops.yaml and rewraps all SOPS-encrypted files.

  .DESCRIPTION
    Derives the machine age public key from the SSH host key at
    C:\ProgramData\ssh\ssh_host_ed25519_key.pub, inserts it into .sops.yaml if
    missing, and rewraps every SOPS-encrypted file. Idempotent: an already
    registered key returns immediately.

    Insertion preserves the existing line-ending style and lands above the
    "# -- machine keys end; personal SSH backup key below --" marker; a missing
    marker fails fast.

    Needs the primary GPG key in the keyring so sops updatekeys can re-encrypt
    data keys for all recipients.
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)]
    [string]$MachineSshHostKeyPubPath,

    [Parameter(Mandatory = $true)]
    [string]$SopsExe,

    [Parameter(Mandatory = $true)]
    [string]$SopsYamlPath,

    [Parameter(Mandatory = $true)]
    [string]$SecretsDir,

    [Parameter(Mandatory = $true)]
    [string]$RepoRoot
  )

  if (-not (Test-Path -Path $MachineSshHostKeyPubPath)) {
    # A freshly installed system may not have the host key yet (OpenSSH server
    # feature not enabled). Warn and skip rather than hard-failing apply.
    Write-NucleusWarning -CommandName 'sops' "$MachineSshHostKeyPubPath not found; skipping machine age key auto-registration."
    return
  }

  # Conversion is passphrase-free: only the public key is read.
  # ConvertFrom-SshEd25519PublicKeyToAgePubKey comes from
  # ConvertFrom-SshEd25519PublicKeyToAgePubKey.ps1, dot-sourced before this file.
  $sshPubKeyLine = (Get-Content -Path $MachineSshHostKeyPubPath -Raw).Trim()
  $agePub = ConvertFrom-SshEd25519PublicKeyToAgePubKey -SshPublicKeyLine $sshPubKeyLine

  # Idempotency: skip insertion and rewrap when this machine is already registered.
  $rawContent = [System.IO.File]::ReadAllText($SopsYamlPath)
  if ($rawContent -like "*$agePub*") {
    Write-NucleusInfo -CommandName 'sops' "machine age key already registered in .sops.yaml; skipping auto-registration."
    return
  }

  Write-NucleusInfo -CommandName 'sops' "registering machine age key in .sops.yaml and rewrapping SOPS files..."

  # .sops.yaml is committed from POSIX with LF, so write back the style found
  # rather than producing a CRLF diff that needs a manual fixup.
  $eol = if ($rawContent.Contains("`r`n")) { "`r`n" } else { "`n" }

  # Insert above the marker that separates machine recipients from the personal
  # SSH backup key, so machine keys always group above the backup entry.
  $marker = "    # -- machine keys end; personal SSH backup key below --"
  $newKeyLine = "    - $agePub"
  if (-not ($rawContent -like "*$marker*")) {
    throw "sops: ERROR — .sops.yaml marker comment not found; cannot insert machine age key.  " +
          "Expected: '$marker'.  Ensure the marker is present in .sops.yaml."
  }
  $newContent = $rawContent.Replace($marker, "$newKeyLine$eol$marker")

  # Write back with UTF-8 without BOM to match the existing file encoding.
  [System.IO.File]::WriteAllText($SopsYamlPath, $newContent, [System.Text.UTF8Encoding]::new($false))

  # Verify the insertion: Replace can silently do nothing on an encoding
  # mismatch or unexpected whitespace in the marker.
  $verifyContent = [System.IO.File]::ReadAllText($SopsYamlPath)
  if (-not ($verifyContent -like "*$agePub*")) {
    throw "sops: ERROR — failed to insert machine age key into .sops.yaml; " +
          "verify the marker comment is present and the file encoding is UTF-8."
  }

  # Rewrap per-user secret YAMLs so the new machine recipient can decrypt them.
  $sopsFiles = @()
  $usersSecretsDir = Join-Path -Path $SecretsDir -ChildPath "users"
  if (Test-Path -Path $usersSecretsDir) {
    $userSecretFiles = Get-ChildItem -Path $usersSecretsDir -Filter "*.yml" -File |
      Select-Object -ExpandProperty FullName
    if ($null -ne $userSecretFiles) {
      $sopsFiles += $userSecretFiles
    }
  }
  # Overlay wallpaper blobs are dynamic, so include whatever exists now.
  $usersRoot = Join-Path -Path $RepoRoot -ChildPath 'src\users'
  if (Test-Path -Path $usersRoot) {
    # check-suppress:suppression_doc: probe -- no encrypted wallpaper blobs may exist; empty result handled.
    $wallpaperBlobs = @(Get-ChildItem -Path $usersRoot -Recurse -Filter '*.sops' -File -ErrorAction SilentlyContinue |
      Where-Object { $_.FullName -match '[\\/]wallpapers[\\/]encrypted[\\/]' })
    if ($wallpaperBlobs.Count -gt 0) {
      $sopsFiles += @($wallpaperBlobs | Select-Object -ExpandProperty FullName)
    }
  }

  foreach ($sopsFile in $sopsFiles) {
    Write-NucleusInfo -CommandName 'sops' "sops updatekeys $sopsFile"
    # --yes skips the interactive "update recipients?" confirmation (sops v3.8+).
    $sopsResult = & $SopsExe updatekeys --yes $sopsFile 2>&1
    if ($LASTEXITCODE -ne 0) {
      # Surface sops stderr so the operator can diagnose GPG key import failures.
      Write-NucleusError -CommandName 'sops' ($sopsResult | Out-String)
      throw ("sops: ERROR — sops updatekeys failed for $sopsFile.  " +
             "Ensure the primary GPG key is imported first: gpg --import <backup-key-file>")
    }
  }

  Write-NucleusInfo -CommandName 'sops' "machine age key registered and SOPS files rewrapped."
  Write-NucleusInfo -CommandName 'sops' "Commit the changes before deploying to other machines:"
  Write-NucleusInfo -CommandName 'sops' "  git add .sops.yaml src/secrets src/users"
  Write-NucleusInfo -CommandName 'sops' "  git commit -m `"chore: register $(hostname) machine age key`""
}
