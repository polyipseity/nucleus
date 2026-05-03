function Resolve-NucleusExecutable {
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
  param(
    [Parameter(Mandatory = $true)]
    [string]$FilePath,

    [Parameter(Mandatory = $true)]
    [string]$GpgExe,

    [Parameter(Mandatory = $true)]
    [string]$HostKeyPath,

    [Parameter(Mandatory = $true)]
    [string]$SopsExe
  )

  $sopsArgs = @("--decrypt", "--output-format", "json", $FilePath)

  if (Test-Path -Path $HostKeyPath) {
    Write-Host "Found host SSH key. Trying host-key decryption first..." -ForegroundColor Green
    $env:SOPS_AGE_SSH_PRIVATE_KEY_FILE = $HostKeyPath

    try {
      return (& $SopsExe @sopsArgs | ConvertFrom-Json)
    }
    catch {
      Write-Host "Host-key decryption failed. Falling back to GPG keyring..." -ForegroundColor Yellow
    }
    finally {
      Remove-Item Env:SOPS_AGE_SSH_PRIVATE_KEY_FILE -ErrorAction SilentlyContinue
    }
  }

  $secretKeyInfo = & $GpgExe --list-secret-keys --with-colons 2>$null
  if (-not $secretKeyInfo -or -not ($secretKeyInfo -match "^(sec|ssb):")) {
    throw "No GPG secret keys detected. Import your encryption subkey before applying."
  }

  Write-Host "Decrypting with GPG keyring..." -ForegroundColor Cyan
  return (& $SopsExe @sopsArgs | ConvertFrom-Json)
}

function Get-NucleusDecryptedBlob {
  param(
    [Parameter(Mandatory = $true)]
    [string]$FilePath,

    [Parameter(Mandatory = $true)]
    [string]$GpgExe,

    [Parameter(Mandatory = $true)]
    [string]$HostKeyPath,

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

      Write-Host "Host-key decryption failed for '$FilePath'. Falling back to GPG keyring..." -ForegroundColor Yellow
    }
    finally {
      Remove-Item Env:SOPS_AGE_SSH_PRIVATE_KEY_FILE -ErrorAction SilentlyContinue
    }
  }

  $secretKeyInfo = & $GpgExe --list-secret-keys --with-colons 2>$null
  if (-not $secretKeyInfo -or -not ($secretKeyInfo -match "^(sec|ssb):")) {
    throw "No GPG secret keys detected. Import your encryption subkey before decrypting binary assets."
  }

  & $SopsExe @sopsArgs
  if ($LASTEXITCODE -ne 0) {
    throw "Failed to decrypt blob '$FilePath'."
  }
}
