function Invoke-JITSecretMaterialization {
  <#
  .SYNOPSIS
    Materializes specific named secret files on demand (JIT).

  .DESCRIPTION
    For each name in $SecretNames, resolves the corresponding .yml file under
    $SecretsDir (appending .yml if omitted) and calls Sync-SecretFile.
    Throws if a requested file does not exist.

  .PARAMETER SecretsDir
    Absolute path to SOPS-encrypted YAML files directory.
  .PARAMETER SecretNames
    Names of the secret files to materialize (without .yml extension).
  .PARAMETER GpgExe
    Absolute path to the gpg executable.
  .PARAMETER HostKeyPath
    Path to this machine's SSH host private key.
  .PARAMETER PrimarySshKeyPath
    Path to the primary user's managed SSH private key.
  .PARAMETER SopsExe
    Absolute path to the sops executable.
  .PARAMETER PrimaryUsername
    Canonical primary username.
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

  if (-not (Test-PrimaryUser -PrimaryUsername $PrimaryUsername)) {
    return
  }

  foreach ($secretName in $SecretNames) {
    $normalizedSecretFile = if ($secretName.EndsWith(".yml")) { $secretName } else { "$secretName.yml" }
    $secretPath = Join-Path -Path $SecretsDir -ChildPath $normalizedSecretFile

    if (-not (Test-Path -Path $secretPath)) {
      throw "Requested JIT secret file was not found: $secretPath"
    }

    Sync-SecretFile -FilePath $secretPath -GpgExe $GpgExe -HostKeyPath $HostKeyPath -PrimarySshKeyPath $PrimarySshKeyPath -SopsExe $SopsExe -PrimaryUsername $PrimaryUsername
  }
}
