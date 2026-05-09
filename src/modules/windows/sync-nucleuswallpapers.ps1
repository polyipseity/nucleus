# modules/windows/sync-nucleuswallpapers.ps1 — Managed wallpaper materialization.
#
# Decrypts wallpaper blobs into the declarative output directory and returns the
# first active file path for DSC token replacement.

function Sync-NucleusWallpapers {
  <#
  .SYNOPSIS
    Decrypts all SOPS-encrypted wallpaper blobs for each managed user and returns
    the path of the first decrypted file (the active wallpaper).

  .DESCRIPTION
    Enumerates all *.sops files in $AssetsDir (sorted alphabetically) and
    decrypts each one to each user's Pictures\wallpapers directory using
    Get-NucleusDecryptedBlob.  The output filename is the blob's base name with
    the .sops extension stripped.

    For each user in $Users, the home directory is resolved via
    [Environment]::GetFolderPath('SpecialFolder', $User) and the wallpaper
    directory is set to $userHome\Pictures\wallpapers\.  The directory is created
    automatically if it does not exist.

    The function returns the path of the first successfully decrypted wallpaper
    so the caller can pass it to Invoke-NucleusWingetConfiguration as the
    __NUCLEUS_ACTIVE_WALLPAPER__ token value.

    No-op (returns $null with a warning) when:
      - $AssetsDir does not exist, or
      - $AssetsDir contains no *.sops files.

  .PARAMETER AssetsDir
    Absolute path to the directory containing SOPS-encrypted wallpaper blobs
    (*.sops files).

  .PARAMETER GpgExe
    Absolute path to the gpg executable.

  .PARAMETER HostKeyPath
    Path to this machine's SSH host private key used as the age decryption key.

  .PARAMETER PrimarySshKeyPath
    Path to the primary user's managed SSH private key used as the final
    fallback age decryption identity.

  .PARAMETER Users
    Array of usernames whose wallpaper directories should be populated.
    Each user's wallpapers are written to $userHome\Pictures\wallpapers\,
    where $userHome is resolved via [Environment]::GetFolderPath('SpecialFolder', $User).

  .PARAMETER SopsExe
    Absolute path to the sops executable.

  .OUTPUTS
    [string]  Absolute path to the first decrypted wallpaper file, or $null
              when no wallpapers were found.

  .EXAMPLE
    $wallpaper = Sync-NucleusWallpapers `
        -AssetsDir '.\assets\wallpapers' `
        -GpgExe 'gpg.exe' `
        -HostKeyPath 'C:\ProgramData\ssh\ssh_host_ed25519_key' `
        -PrimarySshKeyPath "$HOME\.ssh\ssh_personal_polyipseity" `
        -Users @('polyipseity', 'john') `
        -SopsExe 'sops.exe'
    # Wallpapers materialized to C:\Users\polyipseity\Pictures\wallpapers\ and
    # C:\Users\john\Pictures\wallpapers\.  $wallpaper is the active wallpaper path.
  #>
  param(
    [Parameter(Mandatory = $true)]
    [string]$AssetsDir,

    [Parameter(Mandatory = $true)]
    [string]$GpgExe,

    [Parameter(Mandatory = $true)]
    [string]$HostKeyPath,

    [Parameter(Mandatory = $true)]
    [string]$PrimarySshKeyPath,

    [Parameter(Mandatory = $true)]
    [string[]]$Users,

    [Parameter(Mandatory = $true)]
    [string]$SopsExe
  )

  if (-not (Test-Path -Path $AssetsDir)) {
    Write-Host "No wallpaper assets directory found at $AssetsDir; skipping wallpaper sync." -ForegroundColor Yellow
    return $null
  }

  $wallpaperFiles = @(Get-ChildItem -Path $AssetsDir -Filter "*.sops" | Sort-Object Name)
  if ($wallpaperFiles.Count -eq 0) {
    Write-Host "No wallpaper blobs (*.sops) found in $AssetsDir; skipping wallpaper sync." -ForegroundColor Yellow
    return $null
  }

  $activeWallpaperPath = $null

  foreach ($user in $Users) {
    $userHome = [Environment]::GetFolderPath('SpecialFolder', $user)
    $outputDir = Join-Path -Path $userHome -ChildPath 'Pictures\wallpapers'

    if (-not (Test-Path -Path $outputDir)) {
      New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
    }

    foreach ($wallpaperFile in $wallpaperFiles) {
      $outputName = [System.IO.Path]::GetFileNameWithoutExtension($wallpaperFile.Name)
      $outputPath = Join-Path -Path $outputDir -ChildPath $outputName

      # Clear ReadOnly before overwrite so Get-NucleusDecryptedBlob can update
      # the file on subsequent applies.  Mirrors POSIX u+w unlock before install.
      if (Test-Path -LiteralPath $outputPath) {
        $existingWallpaper = Get-Item -LiteralPath $outputPath -Force
        if ($existingWallpaper.Attributes -band [System.IO.FileAttributes]::ReadOnly) {
          $existingWallpaper.Attributes = $existingWallpaper.Attributes -band -bnot [System.IO.FileAttributes]::ReadOnly
        }
      }

      Write-Host "Materializing wallpaper for $user`: $outputName" -ForegroundColor Cyan
      Get-NucleusDecryptedBlob -FilePath $wallpaperFile.FullName -GpgExe $GpgExe -HostKeyPath $HostKeyPath -PrimarySshKeyPath $PrimarySshKeyPath -OutputPath $outputPath -SopsExe $SopsExe

      # Set ReadOnly: managed gallery content must not be modified outside activation.
      # Mirrors POSIX chmod 444.  Applied after write so Get-NucleusDecryptedBlob can
      # create or overwrite the file without attribute conflicts on this apply.
      if (Test-Path -LiteralPath $outputPath) {
        $decryptedWallpaper = Get-Item -LiteralPath $outputPath -Force
        $decryptedWallpaper.Attributes = $decryptedWallpaper.Attributes -bor [System.IO.FileAttributes]::ReadOnly
      }

      if (-not $activeWallpaperPath) {
        $activeWallpaperPath = $outputPath
      }
    }
  }

  Write-Host "Wallpaper sync complete." -ForegroundColor Green
  return $activeWallpaperPath
}
