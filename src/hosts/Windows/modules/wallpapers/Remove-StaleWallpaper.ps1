<#
.SYNOPSIS
  Removes decrypted wallpaper files that no longer have a matching SOPS source blob.

.DESCRIPTION
  Removes only decrypted files without matching source blobs so gallery state
  stays aligned with declarative assets.

.NOTES
  Environment variables: (none)
  Exit codes: 0 on success; non-zero on failure
#>

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
    Absolute path to the directory containing SOPS-encrypted wallpaper blobs
    (*.sops files).

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
  # SilentlyContinue: AssetsDir existence is confirmed by Test-Path above;
  # suppression covers unlikely access-denied errors so the function degrades
  # gracefully (no stale-cleanup) rather than aborting the apply run.
  Get-ChildItem -LiteralPath $AssetsDir -Filter "*.sops" -File -ErrorAction SilentlyContinue |
    ForEach-Object { [void]$managedWallpaperSet.Add([System.IO.Path]::GetFileNameWithoutExtension($_.Name)) }

  # SilentlyContinue: OutputDir existence is confirmed by Test-Path above;
  # suppression covers unlikely access-denied errors (result is null/empty
  # collection, which the foreach handles as a no-op).
  $decryptedWallpapers = Get-ChildItem -LiteralPath $OutputDir -File -ErrorAction SilentlyContinue
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
