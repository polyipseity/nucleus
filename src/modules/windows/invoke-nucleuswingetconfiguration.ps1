# modules/windows/invoke-nucleuswingetconfiguration.ps1 — DSC apply wrapper.
#
# Applies WinGet DSC manifests with managed wallpaper-token replacement while
# preserving source files untouched.

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
