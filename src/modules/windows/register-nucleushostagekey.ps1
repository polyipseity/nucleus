# modules/windows/register-nucleushostagekey.ps1 — Machine age key auto-registration.
#
# Mirrors register_host_age_key_if_needed in src/scripts/apply.sh.
# Derives the machine age public key from the Windows SSH host public key,
# inserts it into .sops.yaml if not already present, and rewraps every
# SOPS-encrypted file so this machine can decrypt them.
#
# ConvertFrom-SshEd25519PublicKeyToAgePubKey is provided by
# convert-sshpublickeytoage.ps1, which apply.ps1 dot-sources before this file
# (alphabetical order ensures 'c' < 'r').

function Register-NucleusHostAgeKey {
  <#
  .SYNOPSIS
    Registers this machine's SSH host public key as an age recipient in
    .sops.yaml and rewraps all SOPS-encrypted files.

  .DESCRIPTION
    Derives the machine age public key from the Windows SSH host key at
    C:\ProgramData\ssh\ssh_host_ed25519_key.pub using
    ConvertFrom-SshEd25519PublicKeyToAgePubKey (a passphrase-free public-key
    conversion; no private key material is accessed).

    If the derived age public key is already present in .sops.yaml the function
    returns immediately (idempotent; safe to call on every apply).

    If the key is new:
      1. Detects and preserves the existing line-ending style of .sops.yaml
         (LF from POSIX commits) to avoid spurious whitespace diffs.
      2. Inserts the new key line immediately before the marker comment
         "    # -- machine keys end; personal SSH backup key below --".
      3. Verifies the insertion succeeded; fails fast if the marker is missing.
      4. Rewraps every SOPS-encrypted file with `sops updatekeys --yes` so the
         new machine recipient can decrypt them.
      5. Prints git commands to commit the changes; does not commit automatically.

    Requires the primary GPG key in the keyring so sops updatekeys can
    re-encrypt data keys for all recipients.  Fails with a clear error and a
    gpg --import hint if GPG decryption fails during sops updatekeys.

  .PARAMETER MachineSshHostKeyPubPath
    Path to this machine's SSH host Ed25519 public key.
    Defaults to C:\ProgramData\ssh\ssh_host_ed25519_key.pub.

  .PARAMETER SopsExe
    Absolute path to the sops executable.

  .PARAMETER SopsYamlPath
    Absolute path to .sops.yaml in the repository root.

  .PARAMETER SecretsDir
    Absolute path to the directory containing the SOPS secret YAML files
    (src/secrets).

  .PARAMETER WallpaperAssetsDir
    Absolute path to the directory containing wallpaper SOPS blobs
    (src/assets/wallpapers).

  .EXAMPLE
    Register-NucleusHostAgeKey `
      -MachineSshHostKeyPubPath 'C:\ProgramData\ssh\ssh_host_ed25519_key.pub' `
      -SopsExe 'C:\...\sops.exe' `
      -SopsYamlPath 'C:\...\nucleus\.sops.yaml' `
      -SecretsDir 'C:\...\nucleus\src\secrets' `
      -WallpaperAssetsDir 'C:\...\nucleus\src\assets\wallpapers'
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
    [string]$WallpaperAssetsDir
  )

  if (-not (Test-Path -Path $MachineSshHostKeyPubPath)) {
    # Advisory: host key may not yet exist on a freshly installed system that
    # has not yet enabled the OpenSSH server feature.  Registration cannot
    # proceed without it; warn and skip rather than hard-failing apply.
    Write-Warning "nucleus: $MachineSshHostKeyPubPath not found; skipping machine age key auto-registration."
    return
  }

  # Derive the age public key from the SSH host public key.  The conversion is
  # passphrase-free: only the public key is required (the private key is not
  # read).  ConvertFrom-SshEd25519PublicKeyToAgePubKey is provided by
  # convert-sshpublickeytoage.ps1, dot-sourced before this file.
  $sshPubKeyLine = (Get-Content -Path $MachineSshHostKeyPubPath -Raw).Trim()
  $agePub = ConvertFrom-SshEd25519PublicKeyToAgePubKey -SshPublicKeyLine $sshPubKeyLine

  # Idempotency: skip insertion and rewrap when this machine is already registered.
  $rawContent = [System.IO.File]::ReadAllText($SopsYamlPath)
  if ($rawContent -like "*$agePub*") {
    Write-Host "nucleus: machine age key already registered in .sops.yaml; skipping auto-registration." -ForegroundColor Gray
    return
  }

  Write-Host "nucleus: registering machine age key in .sops.yaml and rewrapping SOPS files..." -ForegroundColor Cyan

  # Detect the existing line-ending style so the file is written back with the
  # same convention.  .sops.yaml is committed from POSIX systems and uses LF;
  # preserving LF avoids a spurious CRLF diff that would require a manual fixup.
  $eol = if ($rawContent.Contains("`r`n")) { "`r`n" } else { "`n" }

  # Insert the new age key line immediately before the marker comment that
  # separates machine recipients from the personal SSH backup key.  The marker
  # ensures new machine keys are always grouped above the backup entry.
  $marker = "    # -- machine keys end; personal SSH backup key below --"
  $newKeyLine = "    - $agePub"
  if (-not ($rawContent -like "*$marker*")) {
    throw "nucleus: ERROR — .sops.yaml marker comment not found; cannot insert machine age key.  " +
          "Expected: '$marker'.  Ensure the marker is present in .sops.yaml."
  }
  $newContent = $rawContent.Replace($marker, "$newKeyLine$eol$marker")

  # Write back with UTF-8 without BOM to match the existing file encoding.
  [System.IO.File]::WriteAllText($SopsYamlPath, $newContent, [System.Text.UTF8Encoding]::new($false))

  # Verify insertion; catches the case where Replace silently produced no change
  # due to an encoding mismatch or unexpected whitespace in the marker.
  $verifyContent = [System.IO.File]::ReadAllText($SopsYamlPath)
  if (-not ($verifyContent -like "*$agePub*")) {
    throw "nucleus: ERROR — failed to insert machine age key into .sops.yaml; " +
          "verify the marker comment is present and the file encoding is UTF-8."
  }

  # Rewrap the three core secret YAMLs so the new machine recipient can decrypt them.
  $sopsFiles = @(
    (Join-Path -Path $SecretsDir -ChildPath "git-identities.yml"),
    (Join-Path -Path $SecretsDir -ChildPath "gpg-personal.yml"),
    (Join-Path -Path $SecretsDir -ChildPath "ssh-personal.yml")
  )
  # Dynamically include wallpaper blobs so new wallpapers are automatically rewrapped.
  if (Test-Path -Path $WallpaperAssetsDir) {
    $wallpaperBlobs = Get-ChildItem -Path $WallpaperAssetsDir -Filter "*.sops" -File |
      Select-Object -ExpandProperty FullName
    if ($null -ne $wallpaperBlobs) {
      $sopsFiles += $wallpaperBlobs
    }
  }

  foreach ($sopsFile in $sopsFiles) {
    Write-Host "nucleus: sops updatekeys $sopsFile" -ForegroundColor Gray
    # --yes skips the interactive "update recipients?" confirmation (sops v3.8+).
    $sopsResult = & $SopsExe updatekeys --yes $sopsFile 2>&1
    if ($LASTEXITCODE -ne 0) {
      # Surface sops stderr so the operator can diagnose GPG key import failures.
      Write-Error ($sopsResult | Out-String)
      throw ("nucleus: ERROR — sops updatekeys failed for $sopsFile.  " +
             "Ensure the primary GPG key is imported first: gpg --import <backup-key-file>")
    }
  }

  Write-Host "nucleus: machine age key registered and SOPS files rewrapped." -ForegroundColor Green
  Write-Host "nucleus: Commit the changes before deploying to other machines:" -ForegroundColor Yellow
  Write-Host "nucleus:   git add .sops.yaml src/secrets src/assets/wallpapers" -ForegroundColor Yellow
  Write-Host "nucleus:   git commit -m `"chore: register $(hostname) machine age key`"" -ForegroundColor Yellow
}
