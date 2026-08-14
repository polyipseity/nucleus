function Resolve-SecretUserHomedir {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Username
  )

  if ($Username -eq $env:USERNAME -and -not [string]::IsNullOrWhiteSpace($HOME)) {
    return $HOME
  }

  $candidate = Join-Path -Path $env:SystemDrive -ChildPath "Users\$Username"
  if (Test-Path -LiteralPath $candidate -PathType Container) {
    return $candidate
  }

  $userProfileRecord = Get-CimInstance -ClassName Win32_UserProfile -ErrorAction SilentlyContinue |  # check-suppress:suppression_doc: probe -- profile may not exist for every username; Where-Object filters to matches
    Where-Object { $_.LocalPath -match "\\$([regex]::Escape($Username))$" } |
    Select-Object -First 1
  if ($null -ne $userProfileRecord -and -not [string]::IsNullOrWhiteSpace($userProfileRecord.LocalPath)) {
    return $userProfileRecord.LocalPath
  }

  return $null
}

function Get-SecretUserName {
  param(
    [Parameter(Mandatory = $true)]
    [string]$RepoRoot
  )

  $usersDir = Join-Path -Path $RepoRoot -ChildPath 'src\secrets\users'
  if (-not (Test-Path -LiteralPath $usersDir -PathType Container)) {
    return @()
  }

  return @(Get-ChildItem -LiteralPath $usersDir -Filter '*.yml' -File |
    ForEach-Object { $_.BaseName } |
    Sort-Object)
}

function Get-SecretUserSshPrivateKeyPath {
  param(
    [Parameter(Mandatory = $true)]
    [string]$RepoRoot
  )

  $paths = [System.Collections.Generic.List[string]]::new()
  foreach ($username in (Get-SecretUserName -RepoRoot $RepoRoot)) {
    $userHome = Resolve-SecretUserHomedir -Username $username
    if ([string]::IsNullOrWhiteSpace($userHome)) {
      continue
    }

    $manifest = Join-Path -Path $userHome -ChildPath '.config\nucleus\managed-ssh-key-paths'
    if (-not (Test-Path -LiteralPath $manifest -PathType Leaf)) {
      continue
    }

    foreach ($line in (Get-Content -LiteralPath $manifest)) {
      $trimmed = $line.Trim()
      if (-not [string]::IsNullOrWhiteSpace($trimmed)) {
        $paths.Add($trimmed)
      }
    }
  }

  return @($paths)
}

function Invoke-SopsDecrypt {
  param(
    [Parameter(Mandatory = $true)]
    [string]$SopsExe,

    [Parameter(Mandatory = $true)]
    [string[]]$SopsArgs,

    [Parameter(Mandatory = $true)]
    [string]$GpgExe,

    [Parameter(Mandatory = $true)]
    [string]$HostKeyPath,

    [Parameter(Mandatory = $true)]
    [string]$RepoRoot,

    [string]$MachineAgeKeyPath = (Join-Path -Path $env:ProgramData -ChildPath 'nucleus\sops\age\machine.txt'),

    [string]$PrimarySshKeyPath
  )

  $clearAgeEnv = {
    # check-suppress:suppression_doc: cleanup-after-failure in finally block; env var may not be set.
    Remove-Item Env:SOPS_AGE_SSH_PRIVATE_KEY_FILE -ErrorAction Ignore
    # check-suppress:suppression_doc: cleanup-after-failure in finally block; env var may not be set.
    Remove-Item Env:SOPS_AGE_KEY_FILE -ErrorAction Ignore
  }

  if (Test-Path -Path $HostKeyPath) {
    Write-NucleusInfo -CommandName 'Get-Secret' "Found machine SSH key. Trying machine-key decryption first..."
    $env:SOPS_AGE_SSH_PRIVATE_KEY_FILE = $HostKeyPath
    try {
      $output = & $SopsExe @SopsArgs
      if ($LASTEXITCODE -eq 0) {
        return $output
      }

      Write-NucleusInfo -CommandName 'Get-Secret' "Machine-key decryption failed. Trying machine age key file..."
    }
    finally {
      & $clearAgeEnv
    }
  }

  if (Test-Path -LiteralPath $MachineAgeKeyPath -PathType Leaf) {
    Write-NucleusInfo -CommandName 'Get-Secret' "Found machine age key file. Trying machine-age decryption..."
    $env:SOPS_AGE_KEY_FILE = $MachineAgeKeyPath
    try {
      $output = & $SopsExe @SopsArgs
      if ($LASTEXITCODE -eq 0) {
        return $output
      }

      Write-NucleusInfo -CommandName 'Get-Secret' "Machine-age decryption failed. Trying user SSH keys..."
    }
    finally {
      & $clearAgeEnv
    }
  }

  foreach ($userSshKeyPath in (Get-SecretUserSshPrivateKeyPath -RepoRoot $RepoRoot)) {
    if (-not (Test-Path -LiteralPath $userSshKeyPath -PathType Leaf)) {
      continue
    }

    Write-NucleusInfo -CommandName 'Get-Secret' "Trying user SSH key: $userSshKeyPath"
    $env:SOPS_AGE_SSH_PRIVATE_KEY_FILE = $userSshKeyPath
    try {
      $output = & $SopsExe @SopsArgs
      if ($LASTEXITCODE -eq 0) {
        return $output
      }
    }
    finally {
      & $clearAgeEnv
    }
  }

  if (-not [string]::IsNullOrWhiteSpace($PrimarySshKeyPath) -and (Test-Path -Path $PrimarySshKeyPath)) {
    Write-NucleusInfo -CommandName 'Get-Secret' "Found primary SSH key. Trying primary-ssh decryption..."
    $env:SOPS_AGE_SSH_PRIVATE_KEY_FILE = $PrimarySshKeyPath
    try {
      $output = & $SopsExe @SopsArgs
      if ($LASTEXITCODE -eq 0) {
        return $output
      }

      Write-NucleusInfo -CommandName 'Get-Secret' "Primary-ssh decryption failed. Falling back to GPG keyring..."
    }
    finally {
      & $clearAgeEnv
    }
  }

  $secretKeyInfo = & $GpgExe --list-secret-keys --with-colons
  $hasGpgSecretKeys = ($secretKeyInfo -and ($secretKeyInfo -match "^(sec|ssb):"))
  if ($hasGpgSecretKeys) {
    Write-NucleusInfo -CommandName 'Get-Secret' "Decrypting with GPG keyring..."
    $output = & $SopsExe @SopsArgs
    if ($LASTEXITCODE -eq 0) {
      return $output
    }
  }
  else {
    Write-NucleusInfo -CommandName 'Get-Secret' "No GPG secret keys detected."
  }

  return $null
}

function Get-Secret {
  <#
  .SYNOPSIS
    Decrypts a SOPS-encrypted YAML file and returns its contents as a
    PSCustomObject.

  .DESCRIPTION
    Attempts decryption in priority order:
      1. Machine SSH key (age recipient derived from this machine's SSH host key).
      2. Machine age key file when present.
      3. Each private SSH key listed in every user's
         ~/.config/nucleus/managed-ssh-key-paths manifest (users sorted by
         src/secrets/users/*.yml filename).
      4. Optional primary personal SSH key during transition.
      5. GPG keyring.

    The decrypted payload is parsed from JSON and returned as a PowerShell
    object so callers can access named fields with dot notation.

  .PARAMETER FilePath
    Absolute path to the SOPS-encrypted YAML file to decrypt.

  .PARAMETER GpgExe
    Absolute path to the gpg executable.

  .PARAMETER HostKeyPath
    Path to this machine's SSH host private key backing the age recipient.
    When the file does not exist, machine-key decryption is skipped.

  .PARAMETER RepoRoot
    Absolute path to the nucleus repository root (enumerates src/secrets/users).

  .PARAMETER PrimarySshKeyPath
    Optional transition fallback: path to a managed SSH private key tried after
    user manifests and before the GPG keyring.

  .PARAMETER SopsExe
    Absolute path to the sops executable.

  .OUTPUTS
    [PSCustomObject]  Decrypted secret data as a structured object.

  .EXAMPLE
    $secrets = Get-Secret -FilePath '.\secrets.yml' -GpgExe 'gpg.exe' `
      -HostKeyPath 'C:\ProgramData\ssh\ssh_host_ed25519_key' `
      -RepoRoot 'C:\Users\admin\nucleus' -SopsExe 'sops.exe'
  #>
  param(
    [Parameter(Mandatory = $true)]
    [string]$FilePath,

    [Parameter(Mandatory = $true)]
    [string]$GpgExe,

    [Parameter(Mandatory = $true)]
    [string]$HostKeyPath,

    [Parameter(Mandatory = $true)]
    [string]$RepoRoot,

    [Parameter(Mandatory = $true)]
    [string]$SopsExe,

    [string]$PrimarySshKeyPath
  )

  $sopsArgs = @('--decrypt', '--output-type', 'json', $FilePath)
  $decryptedOutput = Invoke-SopsDecrypt `
    -SopsExe $SopsExe `
    -SopsArgs $sopsArgs `
    -GpgExe $GpgExe `
    -HostKeyPath $HostKeyPath `
    -RepoRoot $RepoRoot `
    -PrimarySshKeyPath $PrimarySshKeyPath

  if ($null -eq $decryptedOutput) {
    throw "Unable to decrypt '$FilePath'. Machine SSH key, machine age key, user SSH keys, and GPG keyring were unavailable or failed."
  }

  return ($decryptedOutput | ConvertFrom-Json)
}
