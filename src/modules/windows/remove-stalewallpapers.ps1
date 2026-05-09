# modules/windows/remove-stalewallpapers.ps1 — Managed wallpaper stale-file cleanup.
#
# Removes only decrypted files without matching source blobs so gallery state
# stays aligned with declarative assets.

function Remove-StaleWallpapers {
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
  [CmdletBinding(SupportsShouldProcess = $true)]
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
    # SilentlyContinue: AssetsDir existence is confirmed by Test-Path above;
    # suppression covers unlikely access-denied errors so the function degrades
    # gracefully (no stale-cleanup) rather than aborting the apply run.
    Get-ChildItem -Path $AssetsDir -Filter "*.sops" -File -ErrorAction SilentlyContinue |
      ForEach-Object { [System.IO.Path]::GetFileNameWithoutExtension($_.Name) }
  )

  $managedWallpaperSet = @{}
  foreach ($expectedWallpaperName in $expectedWallpaperNames) {
    $managedWallpaperSet[$expectedWallpaperName] = $true
  }

  # SilentlyContinue: OutputDir existence is confirmed by Test-Path above;
  # suppression covers unlikely access-denied errors (result is null/empty
  # collection, which the foreach handles as a no-op).
  $decryptedWallpapers = Get-ChildItem -Path $OutputDir -File -ErrorAction SilentlyContinue | Sort-Object -Property Name
  foreach ($decryptedWallpaper in $decryptedWallpapers) {
    if ($decryptedWallpaper.Extension -eq ".xml") {
      continue
    }

    if (-not $managedWallpaperSet.ContainsKey($decryptedWallpaper.Name)) {
      # Use -ErrorAction Stop so the catch block can distinguish a real failure
      # (e.g. file locked by the display subsystem) from a successful removal.
      try {
        if ($PSCmdlet.ShouldProcess($decryptedWallpaper.FullName, 'Remove')) {
          Remove-Item -Path $decryptedWallpaper.FullName -Force -ErrorAction Stop
          Write-Output "Removed stale wallpaper: $($decryptedWallpaper.Name)"
        }
      }
      catch {
        Write-Warning "wallpapers: failed to remove stale wallpaper '$($decryptedWallpaper.Name)': $_"
      }
    }
  }
}
