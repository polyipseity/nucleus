# modules/windows/remove-nucleusstalewallpapers.ps1 — Managed wallpaper stale-file cleanup.
#
# Removes only decrypted files without matching source blobs so gallery state
# stays aligned with declarative assets.

function Remove-NucleusStaleWallpapers {
  <#
  .SYNOPSIS
    Removes decrypted wallpaper files that no longer have a matching *.sops
    source blob in the repository.

  .DESCRIPTION
    Compares files in $OutputDir against source blob names in $AssetsDir.
    Any non-XML file in $OutputDir whose name is absent from the source set is
    deleted. This keeps Windows wallpaper state aligned with the declarative
    `assets/wallpapers/*.sops` inventory and prevents stale gallery entries.

  .PARAMETER AssetsDir
    Absolute path to the directory containing SOPS-encrypted wallpaper blobs
    (*.sops files).

  .PARAMETER OutputDir
    Directory containing decrypted wallpaper files.

  .EXAMPLE
    Remove-NucleusStaleWallpapers -AssetsDir '.\assets\wallpapers' -OutputDir "$HOME\Pictures\wallpapers"
  #>
  param(
    [Parameter(Mandatory = $true)]
    [string]$AssetsDir,

    [Parameter(Mandatory = $true)]
    [string]$OutputDir
  )

  if (-not (Test-Path -Path $AssetsDir) -or -not (Test-Path -Path $OutputDir)) {
    return
  }

  $expectedWallpaperNames = @(
    Get-ChildItem -Path $AssetsDir -Filter "*.sops" -File -ErrorAction SilentlyContinue |
      ForEach-Object { [System.IO.Path]::GetFileNameWithoutExtension($_.Name) }
  )

  $managedWallpaperSet = @{}
  foreach ($expectedWallpaperName in $expectedWallpaperNames) {
    $managedWallpaperSet[$expectedWallpaperName] = $true
  }

  $decryptedWallpapers = Get-ChildItem -Path $OutputDir -File -ErrorAction SilentlyContinue | Sort-Object -Property Name
  foreach ($decryptedWallpaper in $decryptedWallpapers) {
    if ($decryptedWallpaper.Extension -eq ".xml") {
      continue
    }

    if (-not $managedWallpaperSet.ContainsKey($decryptedWallpaper.Name)) {
      Remove-Item -Path $decryptedWallpaper.FullName -Force -ErrorAction SilentlyContinue
      Write-Host "Removed stale wallpaper: $($decryptedWallpaper.Name)" -ForegroundColor Yellow
    }
  }
}
