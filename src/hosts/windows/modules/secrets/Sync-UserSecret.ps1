# modules/windows/secrets/Sync-UserSecret.ps1 — Per-user SOPS secret materialization.
#
# Reads src/secrets/<username>.yml (if present) and writes individual secret
# values to the user-scoped secret directory
# $HOME\.config\nucleus\secrets\.
#
# Secrets materialized:
#   rclone_config_pass
#     Written to $HOME\.config\nucleus\secrets\rclone-config-pass.
#     The rclone config passphrase encrypts the entire rclone.conf so stored
#     cloud credentials are protected at rest.  shell profile and
#     Sync-CloudDrive both read this file automatically.
#
# No-op when the per-user secrets file does not exist; machines that have not
# yet created it continue to work without interruption.

function Sync-UserSecret {
  <#
  .SYNOPSIS
    Materializes per-user SOPS secrets to the nucleus secrets directory.

  .DESCRIPTION
    Decrypts src/secrets/<username>.yml (when present) and writes individual
    secret values to $HOME\.config\nucleus\secrets\.  Called by apply.ps1 after
    Sync-Secret to handle user-scoped secrets that do not belong in the shared
    secret files.

  .PARAMETER RepoRoot
    Absolute path to the repository root (for locating src\secrets\<user>.yml).

  .PARAMETER GpgExe
    Absolute path to the gpg executable.

  .PARAMETER HostKeyPath
    Path to this machine's SSH host private key (used by Get-Secret for age
    decryption via the machine identity).

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

  $userSecretFile = Join-Path $RepoRoot "src\secrets\$PrimaryUsername.yml"
  if (-not (Test-Path -Path $userSecretFile -PathType Leaf)) {
    # WHY no warning: the file is optional and absent on first bootstrap; silence
    # keeps apply output clean for machines where the user has not yet created it.
    return
  }

  $secrets = Get-Secret -FilePath $userSecretFile -GpgExe $GpgExe `
    -HostKeyPath $HostKeyPath -PrimarySshKeyPath $PrimarySshKeyPath -SopsExe $SopsExe

  $secretDir = Join-Path $HOME '.config\nucleus\secrets'
  if (-not (Test-Path -Path $secretDir -PathType Container)) {
    New-Item -ItemType Directory -Path $secretDir -Force | Out-Null
  }

  # Materialize rclone config passphrase.
  # WHY key name is unscoped: src/secrets/<username>.yml is already per-user.
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
      # Write without BOM and without a trailing newline so cat-based reads on
      # WSL/POSIX produce the exact passphrase string without trailing whitespace.
      [System.IO.File]::WriteAllText($rclonePassFile, $rclonePassValue, [System.Text.UTF8Encoding]::new($false))
      # WHY restrict to owner-read-only: the passphrase decrypts all rclone
      # credentials; broader permissions would expose them to other local users.
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
