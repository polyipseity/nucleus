<#
.SYNOPSIS
  DSC apply wrapper with wallpaper-token substitution.

.DESCRIPTION
  Applies WinGet DSC manifests with managed wallpaper-token replacement while
  preserving source files untouched.

.NOTES
  Environment variables:
    (none)    No environment variables used.

  Exit codes:
    This module does not emit exit codes.
#>
function Invoke-WingetConfiguration {
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
    Invoke-WingetConfiguration -ConfigPath '.\user\dsc.yml' -WallpaperPath 'C:\Users\primary\Pictures\bg.png'

  .NOTES
    Environment variables:
      (none)    No environment variables used.

    Exit codes:
      0 on success; 1 on error.
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
        # check-suppress:suppression_doc: probe -- registry value may not exist on fresh install; $null check handles absence.
        $existingWallpaperPath = (Get-ItemProperty -Path "HKCU:\Control Panel\Desktop" -Name Wallpaper -ErrorAction SilentlyContinue).Wallpaper
        if (-not [string]::IsNullOrWhiteSpace($existingWallpaperPath)) {
          $effectiveWallpaperPath = $existingWallpaperPath
        }
      }

      if ([string]::IsNullOrWhiteSpace($effectiveWallpaperPath)) {
        $effectiveWallpaperPath = (Join-Path -Path $HOME -ChildPath "Pictures\wallpapers")
      }

      $configContent = $configContent.Replace("__NUCLEUS_ACTIVE_WALLPAPER__", $effectiveWallpaperPath)
      $tempConfigPath = Join-Path -Path $env:TEMP -ChildPath ("winget-config-" + [System.Guid]::NewGuid().ToString() + ".yml")
      $configContent | Out-File -FilePath $tempConfigPath -Encoding utf8 -NoNewline
      $resolvedConfigPath = $tempConfigPath
    }

    Write-NucleusInfo -CommandName 'winget' "Applying WinGet DSC: $resolvedConfigPath"
    winget configure --accept-configuration-agreements --disable-interactivity "$resolvedConfigPath"

    if ($LASTEXITCODE -ne 0) {
      throw "winget configure failed for '$ConfigPath' with exit code $LASTEXITCODE."
    }
  }
  finally {
    if ($tempConfigPath -and (Test-Path -Path $tempConfigPath)) {
      # check-suppress:suppression_doc: cleanup-after-failure in finally block; file may already be gone.
      Remove-Item -Path $tempConfigPath -Force -ErrorAction Ignore
    }
  }
}
