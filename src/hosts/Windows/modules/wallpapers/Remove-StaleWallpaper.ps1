function Remove-StaleWallpaper {
  <#
  .SYNOPSIS
    Removes decrypted wallpaper files that no longer have a matching *.sops
    overlay source blob in the repository.

  .DESCRIPTION
    Compares files in $OutputDir against merged overlay wallpaper blobs for
    $User under src/users/<user>/wallpapers/encrypted/ (with default fallback).
    Any non-XML file in $OutputDir whose name is absent from the overlay set is
    deleted. This keeps Windows wallpaper state aligned with the declarative
    user-overlay inventory and prevents stale gallery entries.

  .PARAMETER OutputDir
    Directory containing decrypted wallpaper files.

  .PARAMETER RepoRoot
    Absolute path to the nucleus repository root.

  .PARAMETER User
    Username whose overlay wallpaper inventory defines managed blobs.

  .EXAMPLE
    Remove-StaleWallpaper -RepoRoot 'C:\nucleus' -User 'admin' -OutputDir "$HOME\Pictures\wallpapers"
  #>
  [CmdletBinding(SupportsShouldProcess = $true)]
  param(
    [Parameter(Mandatory = $true)]
    [string]$RepoRoot,

    [Parameter(Mandatory = $true)]
    [string]$User,

    [Parameter(Mandatory = $true)]
    [string]$OutputDir
  )

  if (-not (Test-Path -LiteralPath $OutputDir -PathType Container)) {
    return
  }

  $managedWallpaperSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
  foreach ($blobName in @(Get-WallpaperEncryptedBlobs -User $User -RepoRoot $RepoRoot)) {
    [void]$managedWallpaperSet.Add([System.IO.Path]::GetFileNameWithoutExtension($blobName))
  }

  if ($managedWallpaperSet.Count -eq 0) {
    return
  }

  # check-suppress:suppression_doc: probe -- output dir may not exist or have no files; empty result handled.
  $decryptedWallpapers = Get-ChildItem -LiteralPath $OutputDir -File -ErrorAction SilentlyContinue
  foreach ($decryptedWallpaper in $decryptedWallpapers) {
    if ($decryptedWallpaper.Extension -eq ".xml") {
      continue
    }

    if (-not $managedWallpaperSet.ContainsKey($decryptedWallpaper.Name)) {
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
