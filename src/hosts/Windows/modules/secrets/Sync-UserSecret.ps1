function Sync-UserSecret {
  <#
  .SYNOPSIS
    Materializes per-user SOPS secrets to the nucleus secrets directory.

  .DESCRIPTION
    Decrypts src/secrets/users-<username>.yml (when present) and writes individual
    secret values to $HOME\.config\nucleus\secrets\.

  .PARAMETER RepoRoot
    Absolute path to the repository root.
  .PARAMETER GpgExe
    Absolute path to the gpg executable.
  .PARAMETER HostKeyPath
    Path to this machine's SSH host private key.
  .PARAMETER PrimarySshKeyPath
    Path to the primary user's managed SSH private key.
  .PARAMETER SopsExe
    Absolute path to the sops executable.
  .PARAMETER PrimaryUsername
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
    [string]$PrimarySshKeyPath,

    [Parameter(Mandatory = $true)]
    [string]$SopsExe,

    [Parameter(Mandatory = $true)]
    [string]$PrimaryUsername
  )

  $userSecretFile = Join-Path $RepoRoot "src\secrets\users-$PrimaryUsername.yml"
  if (-not (Test-Path -Path $userSecretFile -PathType Leaf)) {
    return
  }

  $secrets = Get-Secret -FilePath $userSecretFile -GpgExe $GpgExe `
    -HostKeyPath $HostKeyPath -PrimarySshKeyPath $PrimarySshKeyPath -SopsExe $SopsExe

  $secretDir = Join-Path $HOME '.config\nucleus\secrets'
  if (-not (Test-Path -Path $secretDir -PathType Container)) {
    New-Item -ItemType Directory -Path $secretDir -Force > $null
  }

  $rclonePassKey = 'rclone_config_pass'
  $rclonePassValue = $secrets.$rclonePassKey
  if (-not [string]::IsNullOrWhiteSpace($rclonePassValue)) {
    $rclonePassFile = Join-Path $secretDir 'rclone-config-pass'
    $existing = if (Test-Path -Path $rclonePassFile -PathType Leaf) {
      Get-Content -Path $rclonePassFile -Raw -Encoding UTF8
    }
    else {
      $null
    }
    if ($existing -ne $rclonePassValue) {
      [System.IO.File]::WriteAllText($rclonePassFile, $rclonePassValue, [System.Text.UTF8Encoding]::new($false))
      # Restrict to owner-read-only so the passphrase stays local.
      $acl = Get-Acl -Path $rclonePassFile
      $acl.SetAccessRuleProtection($true, $false)
      $currentIdentity = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
      $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
        $currentIdentity, 'Read', 'Allow'
      )
      $acl.SetAccessRule($rule)
      Set-Acl -Path $rclonePassFile -AclObject $acl
    }
  }

  Write-Output "$($PSStyle.Foreground.Green)user-secrets: per-user secret materialization complete.$($PSStyle.Reset)"
}
