function Remove-StaleWallpaper {
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
    Absolute path to the directory containing SOPS-encrypted wallpaper blobs.

  .PARAMETER OutputDir
    Directory containing decrypted wallpaper files.

  .EXAMPLE
    Remove-StaleWallpaper -AssetsDir '.\assets\wallpapers\admin' -OutputDir "$HOME\Pictures\wallpapers"
  #>
  [CmdletBinding(SupportsShouldProcess = $true)]
  param(
    [Parameter(Mandatory = $true)]
    [string]$AssetsDir,

    [Parameter(Mandatory = $true)]
    [string]$OutputDir
  )

  if (-not (Test-Path -LiteralPath $AssetsDir -PathType Container) -or -not (Test-Path -LiteralPath $OutputDir -PathType Container)) {
    return
  }

  $managedWallpaperSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
  # check-suppress:suppression_doc: probe -- assets dir may not exist or have no .sops files; empty result handled.
  Get-ChildItem -LiteralPath $AssetsDir -Filter "*.sops" -File -ErrorAction SilentlyContinue |
    ForEach-Object {
      [void]$managedWallpaperSet.Add([System.IO.Path]::GetFileNameWithoutExtension($_.Name)) }  # check-suppress:suppression_doc: Add returns bool, discarded


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
