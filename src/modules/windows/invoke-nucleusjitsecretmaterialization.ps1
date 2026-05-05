# modules/windows/invoke-nucleusjitsecretmaterialization.ps1 — Targeted JIT secret sync helper.
#
# Allows modules to request only specific secret files instead of running the
# full baseline sync.

function Invoke-NucleusJitSecretMaterialization {
  <#
  .SYNOPSIS
    Materializes a specific subset of named secret files on demand (JIT).

  .DESCRIPTION
    Designed for modules that need exactly one or two secrets rather than the
    full batch sync.  For each name in $SecretNames, the function resolves the
    corresponding .yml file under $SecretsDir (appending .yml if omitted) and
    calls Sync-NucleusSecretFile.  Throws immediately if a requested secret
    file does not exist.

  .PARAMETER SecretsDir
    Absolute path to the directory containing SOPS-encrypted YAML files.

  .PARAMETER SecretNames
    Names of the secret files to materialize.  The .yml extension is optional;
    it is appended automatically if not present.

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
    Invoke-NucleusJitSecretMaterialization -SecretsDir '.\secrets' `
      -SecretNames @('gpg-personal', 'ssh-personal') `
      -GpgExe 'gpg.exe' -HostKeyPath '...\ssh_host_ed25519_key' `
      -PrimarySshKeyPath "$HOME\.ssh\ssh_personal_polyipseity" -SopsExe 'sops.exe' `
      -PrimaryUsername 'polyipseity'
  #>
  param(
    [Parameter(Mandatory = $true)]
    [string]$SecretsDir,

    [Parameter(Mandatory = $true)]
    [string[]]$SecretNames,

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

  foreach ($secretName in $SecretNames) {
    $normalizedSecretFile = if ($secretName.EndsWith(".yml")) { $secretName } else { "$secretName.yml" }
    $secretPath = Join-Path -Path $SecretsDir -ChildPath $normalizedSecretFile

    if (-not (Test-Path -Path $secretPath)) {
      throw "Requested JIT secret file was not found: $secretPath"
    }

    Sync-NucleusSecretFile -FilePath $secretPath -GpgExe $GpgExe -HostKeyPath $HostKeyPath -PrimarySshKeyPath $PrimarySshKeyPath -SopsExe $SopsExe -PrimaryUsername $PrimaryUsername
  }
}
