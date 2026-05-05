function Resolve-NucleusExecutable {
  <#
  .SYNOPSIS
    Returns the first candidate path that exists on disk.

  .DESCRIPTION
    Iterates $CandidatePaths in order and returns the first path that resolves
    via Test-Path.  Used to locate managed executables (sops, age, gpg) that
    may be installed in different locations depending on how WinGet, Scoop, or a
    manual bootstrap placed them.

  .PARAMETER CandidatePaths
    Ordered list of absolute or relative paths to test.

  .PARAMETER Name
    Display name of the executable, used in the error message when none of the
    candidates are found.

  .OUTPUTS
    [string]  Absolute path of the first candidate that exists.

  .EXAMPLE
    Resolve-NucleusExecutable -Name 'sops' -CandidatePaths @(
      (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages\sops\sops.exe'),
      'C:\ProgramData\scoop\shims\sops.exe'
    )
  #>
  param(
    [Parameter(Mandatory = $true)]
    [string[]]$CandidatePaths,

    [Parameter(Mandatory = $true)]
    [string]$Name
  )

  foreach ($candidatePath in $CandidatePaths) {
    if ($candidatePath -and (Test-Path -Path $candidatePath)) {
      return $candidatePath
    }
  }

  throw "Unable to resolve managed executable path for '$Name'."
}

function Invoke-NucleusWingetConfiguration {
  <#
  .SYNOPSIS
    Applies a WinGet DSC v3 configuration file, substituting the wallpaper path
    token when present.

  .DESCRIPTION
    Reads the YAML at $ConfigPath and replaces the literal token
    __NUCLEUS_ACTIVE_WALLPAPER__ with the effective wallpaper path before
    passing the file to `winget configure`.  Token substitution is performed in
    a temporary file so the source DSC file is never modified on disk.

    Wallpaper path resolution order:
      1. $WallpaperPath parameter (if provided and non-empty)
      2. Current value of HKCU:\Control Panel\Desktop\Wallpaper registry key
      3. $HOME\Pictures\wallpapers (last-resort fallback)

    The temporary file is deleted in a `finally` block whether the run
    succeeds or fails.

  .PARAMETER ConfigPath
    Path to the WinGet DSC YAML file to apply.

  .PARAMETER WallpaperPath
    Optional.  If the DSC file contains the __NUCLEUS_ACTIVE_WALLPAPER__ token,
    this path is substituted in.  When omitted or empty the current registry
    wallpaper or a fallback path is used instead.

  .EXAMPLE
    Invoke-NucleusWingetConfiguration -ConfigPath '.\user.dsc.yml' -WallpaperPath 'C:\Users\me\Pictures\bg.png'
  #>
  param(
    [Parameter(Mandatory = $true)]
    [string]$ConfigPath,

    [Parameter()]
    [string]$WallpaperPath
  )

  if (-not (Test-Path -Path $ConfigPath)) {
    throw "WinGet DSC configuration not found: $ConfigPath"
  }

  $resolvedConfigPath = (Resolve-Path -Path $ConfigPath).Path
  $tempConfigPath = $null

  try {
    $configContent = Get-Content -Path $resolvedConfigPath -Raw

    if ($configContent.Contains("__NUCLEUS_ACTIVE_WALLPAPER__")) {
      $effectiveWallpaperPath = $WallpaperPath

      if ([string]::IsNullOrWhiteSpace($effectiveWallpaperPath)) {
        $existingWallpaperPath = (Get-ItemProperty -Path "HKCU:\Control Panel\Desktop" -Name Wallpaper -ErrorAction SilentlyContinue).Wallpaper
        if (-not [string]::IsNullOrWhiteSpace($existingWallpaperPath)) {
          $effectiveWallpaperPath = $existingWallpaperPath
        }
      }

      if ([string]::IsNullOrWhiteSpace($effectiveWallpaperPath)) {
        $effectiveWallpaperPath = (Join-Path -Path $HOME -ChildPath "Pictures\wallpapers")
      }

      $configContent = $configContent.Replace("__NUCLEUS_ACTIVE_WALLPAPER__", $effectiveWallpaperPath)
      $tempConfigPath = Join-Path -Path $env:TEMP -ChildPath ("nucleus-winget-config-" + [System.Guid]::NewGuid().ToString() + ".yml")
      $configContent | Out-File -FilePath $tempConfigPath -Encoding utf8 -NoNewline
      $resolvedConfigPath = $tempConfigPath
    }

    Write-Host "Applying WinGet DSC: $resolvedConfigPath" -ForegroundColor Cyan
    winget configure --accept-configuration-agreements --disable-interactivity "$resolvedConfigPath"

    if ($LASTEXITCODE -ne 0) {
      throw "winget configure failed for '$ConfigPath' with exit code $LASTEXITCODE."
    }
  }
  finally {
    if ($tempConfigPath -and (Test-Path -Path $tempConfigPath)) {
      Remove-Item -Path $tempConfigPath -Force -ErrorAction SilentlyContinue
    }
  }
}

function Get-NucleusSecrets {
  <#
  .SYNOPSIS
    Decrypts a SOPS-encrypted YAML file and returns its contents as a
    PSCustomObject.

  .DESCRIPTION
    Attempts decryption in priority order:
      1. Machine SSH key (age recipient derived from this machine's SSH host key).
         The key path is passed via the SOPS_AGE_SSH_PRIVATE_KEY_FILE env var
         and cleared in a `finally` block so it is never left in the environment.
      2. GPG keyring.
      3. Primary personal SSH key (age recipient derived from
         ssh_personal_<user>.pub).

    The decrypted payload is parsed from JSON and returned as a PowerShell
    object so callers can access named fields with dot notation.

  .PARAMETER FilePath
    Absolute path to the SOPS-encrypted YAML file to decrypt.

  .PARAMETER GpgExe
    Absolute path to the gpg executable (used for both GPG-path decryption
    and pre-flight key detection).

  .PARAMETER HostKeyPath
    Path to this machine's SSH host private key backing the age recipient.
    When the file does not exist, machine-key decryption is skipped and GPG is
    tried.

  .PARAMETER PrimarySshKeyPath
    Path to the primary user's managed SSH private key used as the final
    fallback age decryption identity.

  .PARAMETER SopsExe
    Absolute path to the sops executable.

  .OUTPUTS
    [PSCustomObject]  Decrypted secret data as a structured object.

  .EXAMPLE
    $secrets = Get-NucleusSecrets -FilePath '.\secrets.yml' -GpgExe 'gpg.exe' `
        -HostKeyPath 'C:\ProgramData\ssh\ssh_host_ed25519_key' `
        -PrimarySshKeyPath "$HOME\.ssh\ssh_personal_polyipseity" -SopsExe 'sops.exe'
    $secrets.ssh_keys
  #>
  param(
    [Parameter(Mandatory = $true)]
    [string]$FilePath,

    [Parameter(Mandatory = $true)]
    [string]$GpgExe,

    [Parameter(Mandatory = $true)]
    [string]$HostKeyPath,

    [Parameter(Mandatory = $true)]
    [string]$PrimarySshKeyPath,

    [Parameter(Mandatory = $true)]
    [string]$SopsExe
  )

  $sopsArgs = @("--decrypt", "--output-format", "json", $FilePath)

  if (Test-Path -Path $HostKeyPath) {
    Write-Host "Found machine SSH key. Trying machine-key decryption first..." -ForegroundColor Green
    $env:SOPS_AGE_SSH_PRIVATE_KEY_FILE = $HostKeyPath

    try {
      return (& $SopsExe @sopsArgs | ConvertFrom-Json)
    }
    catch {
      Write-Host "Machine-key decryption failed. Falling back to GPG keyring..." -ForegroundColor Yellow
    }
    finally {
      Remove-Item Env:SOPS_AGE_SSH_PRIVATE_KEY_FILE -ErrorAction SilentlyContinue
    }
  }

  $secretKeyInfo = & $GpgExe --list-secret-keys --with-colons 2>$null
  $hasGpgSecretKeys = ($secretKeyInfo -and ($secretKeyInfo -match "^(sec|ssb):"))
  if ($hasGpgSecretKeys) {
    try {
      Write-Host "Decrypting with GPG keyring..." -ForegroundColor Cyan
      return (& $SopsExe @sopsArgs | ConvertFrom-Json)
    }
    catch {
      Write-Host "GPG decryption failed. Trying primary SSH key fallback..." -ForegroundColor Yellow
    }
  }
  else {
    Write-Host "No GPG secret keys detected. Trying primary SSH key fallback..." -ForegroundColor Yellow
  }

  if (Test-Path -Path $PrimarySshKeyPath) {
    Write-Host "Found primary SSH key. Trying primary-ssh decryption..." -ForegroundColor Green
    $env:SOPS_AGE_SSH_PRIVATE_KEY_FILE = $PrimarySshKeyPath

    try {
      return (& $SopsExe @sopsArgs | ConvertFrom-Json)
    }
    catch {
      throw "Primary-ssh decryption failed for '$FilePath' after machine-key and GPG attempts."
    }
    finally {
      Remove-Item Env:SOPS_AGE_SSH_PRIVATE_KEY_FILE -ErrorAction SilentlyContinue
    }
  }

  throw "Unable to decrypt '$FilePath'. Machine SSH key, GPG keyring, and primary SSH key were unavailable or failed."
}

function Get-NucleusDecryptedBlob {
  <#
  .SYNOPSIS
    Decrypts a SOPS-encrypted binary blob and writes the plaintext to
    $OutputPath.

  .DESCRIPTION
    Similar key-priority logic to Get-NucleusSecrets (machine SSH key, then GPG,
    then primary SSH key), but uses `sops --output` to write the raw decrypted
    bytes directly to $OutputPath instead of capturing stdout.  Used for binary
    assets such as wallpaper images that cannot be embedded in JSON.

  .PARAMETER FilePath
    Absolute path to the SOPS-encrypted blob file (typically *.sops).

  .PARAMETER GpgExe
    Absolute path to the gpg executable.

  .PARAMETER HostKeyPath
    Path to this machine's SSH host private key backing the age recipient.

  .PARAMETER PrimarySshKeyPath
    Path to the primary user's managed SSH private key used as the final
    fallback age decryption identity.

  .PARAMETER OutputPath
    Destination path where the decrypted bytes will be written.

  .PARAMETER SopsExe
    Absolute path to the sops executable.

  .EXAMPLE
    Get-NucleusDecryptedBlob -FilePath '.\wallpaper.jpg.sops' -GpgExe 'gpg.exe' `
    -HostKeyPath 'C:\ProgramData\ssh\ssh_host_ed25519_key' `
    -PrimarySshKeyPath "$HOME\.ssh\ssh_personal_polyipseity" `
    -OutputPath 'C:\Users\me\Pictures\wallpaper.jpg' -SopsExe 'sops.exe'
  #>
  param(
    [Parameter(Mandatory = $true)]
    [string]$FilePath,

    [Parameter(Mandatory = $true)]
    [string]$GpgExe,

    [Parameter(Mandatory = $true)]
    [string]$HostKeyPath,

    [Parameter(Mandatory = $true)]
    [string]$PrimarySshKeyPath,

    [Parameter(Mandatory = $true)]
    [string]$OutputPath,

    [Parameter(Mandatory = $true)]
    [string]$SopsExe
  )

  $sopsArgs = @("--decrypt", "--output", $OutputPath, $FilePath)

  if (Test-Path -Path $HostKeyPath) {
    $env:SOPS_AGE_SSH_PRIVATE_KEY_FILE = $HostKeyPath

    try {
      & $SopsExe @sopsArgs
      if ($LASTEXITCODE -eq 0) {
        return
      }

      Write-Host "Machine-key decryption failed for '$FilePath'. Falling back to GPG keyring..." -ForegroundColor Yellow
    }
    finally {
      Remove-Item Env:SOPS_AGE_SSH_PRIVATE_KEY_FILE -ErrorAction SilentlyContinue
    }
  }

  $secretKeyInfo = & $GpgExe --list-secret-keys --with-colons 2>$null
  $hasGpgSecretKeys = ($secretKeyInfo -and ($secretKeyInfo -match "^(sec|ssb):"))
  if ($hasGpgSecretKeys) {
    & $SopsExe @sopsArgs
    if ($LASTEXITCODE -eq 0) {
      return
    }

    Write-Host "GPG decryption failed for '$FilePath'. Trying primary SSH key fallback..." -ForegroundColor Yellow
  }
  else {
    Write-Host "No GPG secret keys detected. Trying primary SSH key fallback for '$FilePath'..." -ForegroundColor Yellow
  }

  if (Test-Path -Path $PrimarySshKeyPath) {
    Write-Host "Found primary SSH key. Trying primary-ssh decryption for '$FilePath'..." -ForegroundColor Green
    $env:SOPS_AGE_SSH_PRIVATE_KEY_FILE = $PrimarySshKeyPath

    try {
      & $SopsExe @sopsArgs
      if ($LASTEXITCODE -eq 0) {
        return
      }

      throw "Primary-ssh decryption failed for '$FilePath' after machine-key and GPG attempts."
    }
    finally {
      Remove-Item Env:SOPS_AGE_SSH_PRIVATE_KEY_FILE -ErrorAction SilentlyContinue
    }
  }

  throw "Failed to decrypt blob '$FilePath'. Machine SSH key, GPG keyring, and primary SSH key were unavailable or failed."
}
