# modules/windows/sync-wallpaper.ps1 — Managed wallpaper materialization.

# Decrypts wallpaper blobs into the declarative output directory and returns the
# first active file path for DSC token replacement.

function Sync-Wallpaper {
  <#
  .SYNOPSIS
    Decrypts all SOPS-encrypted wallpaper blobs for each managed user and returns
    the path of the first decrypted file (the active wallpaper).

  .DESCRIPTION
    Materializes SOPS-encrypted wallpaper blobs for each user in the $Users
    list. For each user, the *.sops files in $AssetsDir/$User are decrypted
    to that user's Pictures\wallpapers directory using Get-DecryptedBlob.
    The output filename is the blob's base name with the .sops extension
    stripped.

    For each user, the home directory is resolved via the registry and the
    wallpaper directory is set to $userHome\Pictures\wallpapers\. The
    directory is created automatically if it does not exist.

    The function returns the path of the first successfully decrypted
    wallpaper so the caller can pass it to
    Invoke-WingetConfiguration as the __NUCLEUS_ACTIVE_WALLPAPER__ token.

    No-op (returns $null with a warning) when:
      - $AssetsDir does not exist, or
      - No user subdirectories matching $Users exist in $AssetsDir.

  .PARAMETER AssetsDir
    Absolute path to the directory containing user subdirectories with
    SOPS-encrypted wallpaper blobs (*.sops files). Subdirectory names
    must match usernames in the $Users list.

  .PARAMETER GpgExe
    Absolute path to the gpg executable.

  .PARAMETER HostKeyPath
    Path to this machine's SSH host private key used as the age decryption key.

  .PARAMETER PrimarySshKeyPath
    Path to the primary user's managed SSH private key used as the final
    fallback age decryption identity.

  .PARAMETER Users
    Mandatory: array of usernames for which wallpapers should be materialized.
    Only user subdirectories matching names in this list are processed. Callers
    must pass this explicitly so they are aware of which users' wallpapers will
    be decrypted and written to their home directories.

  .PARAMETER SopsExe
    Absolute path to the sops executable.

  .OUTPUTS
    [string]  Absolute path to the first decrypted wallpaper file, or $null
              when no wallpapers were found.

  .EXAMPLE
    $wallpaper = Sync-Wallpaper `
        -AssetsDir 'C:\Users\admin\nucleus\src\assets\wallpapers' `
        -GpgExe 'gpg.exe' `
        -HostKeyPath 'C:\ProgramData\ssh\ssh_host_ed25519_key' `
        -PrimarySshKeyPath "C:\Users\admin\.ssh\ssh_personal_admin" `
        -Users @('admin', 'guest') `
        -SopsExe 'sops.exe'
    # Wallpapers materialized to C:\Users\admin\Pictures\wallpapers\ and
    # C:\Users\guest\Pictures\wallpapers\. $wallpaper is the first active path.
  #>
  param(
    [Parameter(Mandatory = $true)]
    [string]$AssetsDir,

    [Parameter(Mandatory = $true)]
    [string]$GpgExe,

    [Parameter(Mandatory = $true)]
    [string]$HostKeyPath,

    [Parameter(Mandatory = $false)]
    [string]$PrimarySshKeyPath,

    [Parameter(Mandatory = $true)]
    [string[]]$Users,

    [Parameter(Mandatory = $true)]
    [string]$SopsExe
  )

  if (-not (Test-Path -Path $AssetsDir)) {
    Write-Output "$($PSStyle.Foreground.Yellow)Wallpaper assets directory not found at $AssetsDir; skipping wallpaper sync.$($PSStyle.Reset)"
    return $null
  }

  # Only process user subdirectories explicitly listed in $Users.
  $userDirs = @(Get-ChildItem -Path $AssetsDir -Directory | Where-Object { $Users -contains $_.Name } | Sort-Object Name)
  if ($userDirs.Count -eq 0) {
    Write-Output "$($PSStyle.Foreground.Yellow)No user subdirectories matching specified users found in $AssetsDir; skipping wallpaper sync.$($PSStyle.Reset)"
    return $null
  }

  $activeWallpaperPath = $null

  foreach ($userDir in $userDirs) {
    $user = $userDir.Name
    $wallpaperFiles = @(Get-ChildItem -Path $userDir.FullName -Filter "*.sops" | Sort-Object Name)

    if ($wallpaperFiles.Count -eq 0) {
      Write-Output "$($PSStyle.Foreground.Yellow)No wallpaper blobs (*.sops) found in $userDir.FullName; skipping.$($PSStyle.Reset)"
      continue
    }

    $userHome = [Environment]::GetFolderPath('SpecialFolder', $user)
    $outputDir = Join-Path -Path $userHome -ChildPath 'Pictures\wallpapers'

    if (-not (Test-Path -Path $outputDir)) {
      New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
    }

    foreach ($wallpaperFile in $wallpaperFiles) {
      $outputName = [System.IO.Path]::GetFileNameWithoutExtension($wallpaperFile.Name)
      $outputPath = Join-Path -Path $outputDir -ChildPath $outputName

      if (Test-Path -LiteralPath $outputPath) {
        $existingWallpaper = Get-Item -LiteralPath $outputPath -Force
        if ($existingWallpaper.Attributes -band [System.IO.FileAttributes]::ReadOnly) {
          $existingWallpaper.Attributes = $existingWallpaper.Attributes -band -bnot [System.IO.FileAttributes]::ReadOnly
        }
      }

      Write-Output "$($PSStyle.Foreground.Cyan)Materializing wallpaper for $user`: $outputName$($PSStyle.Reset)"
      Get-DecryptedBlob -FilePath $wallpaperFile.FullName -GpgExe $GpgExe -HostKeyPath $HostKeyPath -PrimarySshKeyPath $PrimarySshKeyPath -OutputPath $outputPath -SopsExe $SopsExe

      if (Test-Path -LiteralPath $outputPath) {
        $decryptedWallpaper = Get-Item -LiteralPath $outputPath -Force
        $decryptedWallpaper.Attributes = $decryptedWallpaper.Attributes -bor [System.IO.FileAttributes]::ReadOnly
      }

      if (-not $activeWallpaperPath) {
        $activeWallpaperPath = $outputPath
      }
    }
  }

  Write-Output "$($PSStyle.Foreground.Green)Wallpaper sync complete.$($PSStyle.Reset)"
  return $activeWallpaperPath
}
