# modules/windows/sync-secret.ps1 — Baseline managed secret sync entrypoint.
#
# Materializes the fixed secret inventory expected by Windows host orchestration.

function Sync-Secret {
  <#
  .SYNOPSIS
    Materializes personal SSH/GPG secrets for users that have secrets defined.

  .DESCRIPTION
    Iterates over three SOPS-encrypted secret files (sorted):
      - git-identities.yml
      - gpg-personal.yml
      - ssh-personal.yml

    For each file, decrypts it and checks which users in $Users have secrets
    defined (keys matching `gpg_personal_<username>`, `git_identity_<username>`,
    `ssh_personal_<username>`, `ssh_personal_<username>_pub`,
    `ssh_personal_<username>_rsa`, or `ssh_personal_<username>_rsa_pub`).
    Only those users are passed to Sync-SecretFile.  Users that have
    no secrets in a given file are skipped gracefully.  Each user may have
    a different set of secrets (or none); the function materializes only what
    is actually defined for each user.

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

  .PARAMETER Users
    Array of usernames for which to materialize/import secrets.

  .EXAMPLE
    Sync-Secrets -SecretsDir '.\secrets' -GpgExe 'gpg.exe' `
      -HostKeyPath 'C:\ProgramData\ssh\ssh_host_ed25519_key' `
      -PrimarySshKeyPath "C:\Users\admin\.ssh\ssh_personal_admin" -SopsExe 'sops.exe' `
      -Users @('admin', 'guest')
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
    [string[]]$Users
  )

  if (-not (Test-Path -Path $SecretsDir)) {
    Write-Output "$($PSStyle.Foreground.Yellow)No secrets directory found at $SecretsDir; skipping key provisioning.$($PSStyle.Reset)"
    return
  }

  foreach ($secretFileName in @("git-identities.yml", "gpg-personal.yml", "ssh-personal.yml")) {
    $secretPath = Join-Path -Path $SecretsDir -ChildPath $secretFileName
    if (-not (Test-Path -Path $secretPath)) {
      Write-Output "$($PSStyle.Foreground.Yellow)Required secret file was not found: $secretPath$($PSStyle.Reset)"
      continue
    }

    $decryptedContent = & $SopsExe -d $secretPath 2>&1
    if ($LASTEXITCODE -ne 0) {
      Write-Output "$($PSStyle.Foreground.Yellow)sops: failed to decrypt $secretFileName; skipping$($PSStyle.Reset)"
      continue
    }

    $decryptedYaml = $decryptedContent | ConvertFrom-Yaml -Ordered
    $secretKeys = @($decryptedYaml.PSObject.Properties.Name)
    $usersInThisFile = @()

    foreach ($user in $Users) {
      $hasSecret = $false
      foreach ($key in $secretKeys) {
        if ($key -cmatch "_${user}$" -or $key -eq "git_identity_$user" -or $key -eq "gpg_personal_$user" -or $key -eq "ssh_personal_$user") {
          $hasSecret = $true
          break
        }
      }
      if ($hasSecret) {
        $usersInThisFile += $user
      }
    }

    if ($usersInThisFile.Count -eq 0) {
      continue
    }

    foreach ($user in $usersInThisFile) {
      Sync-SecretFile -FilePath $secretPath -GpgExe $GpgExe -HostKeyPath $HostKeyPath -PrimarySshKeyPath $PrimarySshKeyPath -SopsExe $SopsExe -PrimaryUsername $user
    }
  }
}
