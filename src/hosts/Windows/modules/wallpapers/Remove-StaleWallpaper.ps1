function Remove-StaleWallpaper {
  <#
  .SYNOPSIS
    Removes deployed wallpaper files that no longer have a matching overlay source.

  .DESCRIPTION
    Compares files in $OutputDir against merged overlay wallpaper inventory for
    $User under src/users/<user>/wallpapers/encrypted/ and
    wallpapers/wallpapers/. Any non-XML file absent from the overlay set is
    deleted.

  .PARAMETER OutputDir
    Directory containing deployed wallpaper files.

  .PARAMETER RepoRoot
    Absolute path to the nucleus repository root.

  .PARAMETER User
    Username whose overlay wallpaper inventory defines managed sources.

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
  foreach ($blobName in @(Get-WallpaperEncryptedBlobList -User $User -RepoRoot $RepoRoot)) {
    [void]$managedWallpaperSet.Add([System.IO.Path]::GetFileNameWithoutExtension($blobName))
  }
  foreach ($fileName in @(Get-WallpaperUnencryptedFileList -User $User -RepoRoot $RepoRoot)) {
    [void]$managedWallpaperSet.Add($fileName)
  }

  if ($managedWallpaperSet.Count -eq 0) {
    return
  }

  # check-suppress:suppression_doc: probe -- output dir may not exist or have no files; empty result handled.
  $deployedWallpapers = Get-ChildItem -LiteralPath $OutputDir -Force -ErrorAction SilentlyContinue |
    Where-Object { -not $_.PSIsContainer }
  foreach ($deployedWallpaper in $deployedWallpapers) {
    if ($deployedWallpaper.Extension -eq ".xml") {
      continue
    }

    if (-not $managedWallpaperSet.Contains($deployedWallpaper.Name)) {
      try {
        if ($PSCmdlet.ShouldProcess($deployedWallpaper.FullName, 'Remove')) {
          Remove-Item -Path $deployedWallpaper.FullName -Force -ErrorAction Stop
          Write-Output "Removed stale wallpaper: $($deployedWallpaper.Name)"
        }
      }
      catch {
        Write-Warning "wallpapers: failed to remove stale wallpaper '$($deployedWallpaper.Name)': $_"
      }
    }
  }
}
