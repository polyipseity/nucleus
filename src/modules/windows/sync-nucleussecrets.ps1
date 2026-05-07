# modules/windows/sync-nucleussecrets.ps1 — Baseline managed secret sync entrypoint.
#
# Materializes the fixed secret inventory expected by Windows host orchestration.

function Sync-NucleusSecrets {
  <#
  .SYNOPSIS
    Materializes primary-user personal SSH/GPG secrets from fixed secret files.

  .DESCRIPTION
    Resolves exactly three secret files from $SecretsDir (sorted):
      - git-identities.yml
      - gpg-personal.yml
      - ssh-personal.yml

    Each file is passed to Sync-NucleusSecretFile, which extracts only
    primary-user keys (`gpg_personal_${username}`, `git_identity_${username}`,
    `ssh_personal_${username}`, `ssh_personal_${username}_pub`,
    `ssh_personal_${username}_rsa`, and `ssh_personal_${username}_rsa_pub`)
    and ignores all other keys.

  .PARAMETER SecretsDir
    Absolute path to the directory containing SOPS-encrypted YAML files.

  .PARAMETER GpgExe
    Absolute path to the gpg executable.

  .PARAMETER HostKeyPath
    Path to this machine's SSH host private key used as the age decryption key.

  .PARAMETER PrimarySshKeyPath
    Path to the primary user's managed SSH private key used as the final
    fallback age decryption identity.

  .PARAMETER SopsExe
    Absolute path to the sops executable.

  .PARAMETER PrimaryUsername
    Canonical primary username allowed to materialize/import secrets.

  .EXAMPLE
    Sync-NucleusSecrets -SecretsDir '.\secrets' -GpgExe 'gpg.exe' `
      -HostKeyPath 'C:\ProgramData\ssh\ssh_host_ed25519_key' `
      -PrimarySshKeyPath "$HOME\.ssh\ssh_personal_polyipseity" -SopsExe 'sops.exe' `
      -PrimaryUsername 'polyipseity'
  #>
  param(
    [Parameter(Mandatory = $true)]
    [string]$SecretsDir,

    [Parameter(Mandatory = $true)]
    [string]$GpgExe,

    [Parameter(Mandatory = $true)]
    [string]$HostKeyPath,

    [Parameter(Mandatory = $true)]
    [string]$PrimarySshKeyPath,

    [Parameter(Mandatory = $true)]
    [string]$SopsExe,

    [Parameter(Mandatory = $true)]
    [string]$PrimaryUsername
  )

  if (-not (Test-NucleusPrimaryUser -PrimaryUsername $PrimaryUsername)) {
    return
  }

  if (-not (Test-Path -Path $SecretsDir)) {
    Write-Host "No secrets directory found at $SecretsDir; skipping key provisioning." -ForegroundColor Yellow
    return
  }

  foreach ($secretFileName in @("git-identities.yml", "gpg-personal.yml", "ssh-personal.yml")) {
    $secretPath = Join-Path -Path $SecretsDir -ChildPath $secretFileName
    if (-not (Test-Path -Path $secretPath)) {
      Write-Host "Required secret file was not found: $secretPath" -ForegroundColor Yellow
      continue
    }

    Sync-NucleusSecretFile -FilePath $secretPath -GpgExe $GpgExe -HostKeyPath $HostKeyPath -PrimarySshKeyPath $PrimarySshKeyPath -SopsExe $SopsExe -PrimaryUsername $PrimaryUsername
  }
}
