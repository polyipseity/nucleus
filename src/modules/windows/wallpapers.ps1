# modules/windows/wallpapers.ps1 — Decrypts SOPS wallpaper blobs into the
# managed wallpaper directory used by Windows DSC resources.
#
# Keep all reusable wallpaper logic here (decryption, stale cleanup). The
# host-level apply script remains orchestration-only.

function Sync-NucleusWallpapers {
  <#
  .SYNOPSIS
    Decrypts all SOPS-encrypted wallpaper blobs and returns the path of the
    first decrypted file (the active wallpaper).

  .DESCRIPTION
    Enumerates all *.sops files in $AssetsDir (sorted alphabetically) and
    decrypts each one to $OutputDir using Get-NucleusDecryptedBlob.  The output
    filename is the blob's base name with the .sops extension stripped.

    The function returns the path of the first successfully decrypted wallpaper
    so the caller can pass it to Invoke-NucleusWingetConfiguration as the
    __NUCLEUS_ACTIVE_WALLPAPER__ token value.

    No-op (returns $null with a warning) when:
      - $AssetsDir does not exist, or
      - $AssetsDir contains no *.sops files.

    $OutputDir is created automatically if it does not exist.

  .PARAMETER AssetsDir
    Absolute path to the directory containing SOPS-encrypted wallpaper blobs
    (*.sops files).

  .PARAMETER GpgExe
    Absolute path to the gpg executable.

  .PARAMETER HostKeyPath
    Path to the SSH host private key used as the age decryption key.

  .PARAMETER OutputDir
    Directory where decrypted wallpaper files will be written.

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
        -OutputDir "$HOME\Pictures\wallpapers" `
        -SopsExe 'sops.exe'
    # $wallpaper is now the path to the active wallpaper, or $null.
  #>
  param(
    [Parameter(Mandatory = $true)]
    [string]$AssetsDir,

    [Parameter(Mandatory = $true)]
    [string]$GpgExe,

    [Parameter(Mandatory = $true)]
    [string]$HostKeyPath,

    [Parameter(Mandatory = $true)]
    [string]$OutputDir,

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

  if (-not (Test-Path -Path $OutputDir)) {
    New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
  }

  $activeWallpaperPath = $null

  foreach ($wallpaperFile in $wallpaperFiles) {
    $outputName = [System.IO.Path]::GetFileNameWithoutExtension($wallpaperFile.Name)
    $outputPath = Join-Path -Path $OutputDir -ChildPath $outputName

    Write-Host "Materializing wallpaper: $outputName" -ForegroundColor Cyan
    Get-NucleusDecryptedBlob -FilePath $wallpaperFile.FullName -GpgExe $GpgExe -HostKeyPath $HostKeyPath -OutputPath $outputPath -SopsExe $SopsExe

    if (-not $activeWallpaperPath) {
      $activeWallpaperPath = $outputPath
    }
  }

  Write-Host "Wallpaper sync complete." -ForegroundColor Green
  return $activeWallpaperPath
}

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
