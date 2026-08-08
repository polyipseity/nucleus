function Invoke-JITSecretMaterialization {
  <#
  .SYNOPSIS
    Materializes specific per-user secret files on demand (JIT).

  .DESCRIPTION
    For each name in $SecretNames, resolves src/secrets/users/<name>.yml and
    calls Sync-SecretFile. Throws if a requested file does not exist.

  .PARAMETER RepoRoot
    Absolute path to the nucleus repository root.
  .PARAMETER SecretNames
    Usernames whose per-user secret files should be materialized.
  .PARAMETER GpgExe
    Absolute path to the gpg executable.
  .PARAMETER HostKeyPath
    Path to this machine's SSH host private key.
  .PARAMETER PrimarySshKeyPath
    Optional transition fallback passed through to Sync-SecretFile.
  .PARAMETER SopsExe
    Absolute path to the sops executable.
  .PARAMETER Username
    Username whose home directory receives materialized payloads.
  #>
  param(
    [Parameter(Mandatory = $true)]
    [string]$RepoRoot,

    [Parameter(Mandatory = $true)]
    [string[]]$SecretNames,

    [Parameter(Mandatory = $true)]
    [string]$GpgExe,

    [Parameter(Mandatory = $true)]
    [string]$HostKeyPath,

    [Parameter(Mandatory = $true)]
    [string]$SopsExe,

    [Parameter(Mandatory = $true)]
    [string]$Username,

    [string]$PrimarySshKeyPath
  )

  foreach ($secretName in $SecretNames) {
    $normalizedUserFile = if ($secretName.EndsWith('.yml')) { $secretName } else { "$secretName.yml" }
    $secretPath = Join-Path -Path $RepoRoot -ChildPath (Join-Path -Path 'src\secrets\users' -ChildPath $normalizedUserFile)

    if (-not (Test-Path -Path $secretPath)) {
      throw "Requested JIT secret file was not found: $secretPath"
    }

    $syncParams = @{
      FilePath    = $secretPath
      GpgExe      = $GpgExe
      HostKeyPath = $HostKeyPath
      RepoRoot    = $RepoRoot
      SopsExe     = $SopsExe
      Username    = $Username
    }
    if (-not [string]::IsNullOrWhiteSpace($PrimarySshKeyPath)) {
      $syncParams['PrimarySshKeyPath'] = $PrimarySshKeyPath
    }

    Sync-SecretFile @syncParams
  }
}
