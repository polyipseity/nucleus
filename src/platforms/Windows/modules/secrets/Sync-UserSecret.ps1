function Sync-UserSecret {
  <#
  .SYNOPSIS
    Materializes per-user SOPS secrets for one managed user.

  .DESCRIPTION
    Decrypts src/secrets/users/<username>.yml (when present) via Sync-SecretFile.

  .PARAMETER RepoRoot
    Absolute path to the repository root.
  .PARAMETER GpgExe
    Absolute path to the gpg executable.
  .PARAMETER HostKeyPath
    Path to this machine's SSH host private key.
  .PARAMETER PrimarySshKeyPath
    Optional transition fallback passed through to Sync-SecretFile.
  .PARAMETER SopsExe
    Absolute path to the sops executable.
  .PARAMETER Username
    Username whose per-user secrets file to materialize.
  #>
  param(
    [Parameter(Mandatory = $true)]
    [string]$RepoRoot,

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

  $userSecretFile = Join-Path $RepoRoot "src\secrets\users\$Username.yml"
  if (-not (Test-Path -Path $userSecretFile -PathType Leaf)) {
    return
  }

  $syncParams = @{
    FilePath    = $userSecretFile
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

  Write-Output "$($PSStyle.Foreground.Green)user-secrets: per-user secret materialization complete for '$Username'.$($PSStyle.Reset)"
}
