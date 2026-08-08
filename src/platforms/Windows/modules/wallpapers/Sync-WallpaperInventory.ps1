function Sync-WallpaperInventory {
  <#
  .SYNOPSIS
    Materializes overlay wallpapers for each managed user and returns the path
    of the first deployed file (the active wallpaper).

  .DESCRIPTION
    Decrypts SOPS blobs from src/users/<user>/wallpapers/encrypted/ and symlinks
    unencrypted images from wallpapers/wallpapers/ into each user's
    Pictures\wallpapers directory.

    The function returns the path of the first successfully deployed wallpaper
    so the caller can pass it to Invoke-WingetConfiguration as the
    __NUCLEUS_ACTIVE_WALLPAPER__ token.

  .PARAMETER GpgExe
    Absolute path to the gpg executable.

  .PARAMETER HostKeyPath
    Path to this machine's SSH host private key used as the age decryption key.

  .PARAMETER PrimarySshKeyPath
    Path to the primary user's managed SSH private key used as the final
    fallback age decryption identity.

  .PARAMETER RepoRoot
    Absolute path to the nucleus repository root.

  .PARAMETER Users
    Array of usernames for which wallpapers should be materialized.

  .PARAMETER SopsExe
    Absolute path to the sops executable.

  .OUTPUTS
    [string]  Absolute path to the first deployed wallpaper file, or $null
              when no wallpapers were found.

  .EXAMPLE
    Sync-WallpaperInventory `
        -RepoRoot 'C:\Users\admin\nucleus' `
        -GpgExe 'gpg.exe' `
        -HostKeyPath 'C:\ProgramData\ssh\ssh_host_ed25519_key' `
        -PrimarySshKeyPath "C:\Users\admin\.ssh\ssh_personal_admin" `
        -Users 'admin', 'guest' `
        -SopsExe 'sops.exe'
  #>
  # check-suppress:SuppressMessageAttribute: PSReviewUnusedParameter -- empty scope suppresses unused parameter warning on the whole param block
  [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '')]
  param(
    [Parameter(Mandatory = $true)]
    [string]$RepoRoot,

    [Parameter(Mandatory = $true)]
    [string]$GpgExe,

    [Parameter(Mandatory = $true)]
    [string]$HostKeyPath,

    [Parameter()]
    [string]$PrimarySshKeyPath,

    [Parameter(Mandatory = $true)]
    [string[]]$Users,

    [Parameter(Mandatory = $true)]
    [string]$SopsExe
  )

  . (Join-Path -Path $PSScriptRoot -ChildPath '..\Set-ManagedSymlinkDeleteProtection.ps1')

  $activeWallpaperPath = $null

  foreach ($user in ($Users | Sort-Object)) {
    $wallpaperFiles = @(Get-WallpaperEncryptedBlobList -User $user -RepoRoot $RepoRoot)
    $unencryptedFiles = @(Get-WallpaperUnencryptedFileList -User $user -RepoRoot $RepoRoot)

    if ($wallpaperFiles.Count -eq 0 -and $unencryptedFiles.Count -eq 0) {
      Write-Output "$($PSStyle.Foreground.Yellow)No overlay wallpaper sources found for user $user; skipping.$($PSStyle.Reset)"
      continue
    }

    $userHome = [Environment]::GetFolderPath('SpecialFolder', $user)
    $outputDir = Join-Path -Path $userHome -ChildPath 'Pictures\wallpapers'

    if (-not (Test-Path -Path $outputDir)) {
      New-Item -ItemType Directory -Path $outputDir -Force > $null
    }

    foreach ($wallpaperBlobName in $wallpaperFiles) {
      $wallpaperFilePath = Resolve-WallpaperEncryptedBlob -User $user -BlobName $wallpaperBlobName -RepoRoot $RepoRoot
      $outputName = [System.IO.Path]::GetFileNameWithoutExtension($wallpaperBlobName)
      $outputPath = Join-Path -Path $outputDir -ChildPath $outputName

      if (Test-Path -LiteralPath $outputPath) {
        $existingWallpaper = Get-Item -LiteralPath $outputPath -Force
        if ($existingWallpaper.Attributes -band [System.IO.FileAttributes]::ReadOnly) {
          $existingWallpaper.Attributes = $existingWallpaper.Attributes -band -bnot [System.IO.FileAttributes]::ReadOnly
        }
      }

      Write-Output "$($PSStyle.Foreground.Cyan)Materializing wallpaper for $user`: $outputName$($PSStyle.Reset)"
      $getDecryptedBlobParams = @{
        FilePath    = $wallpaperFilePath
        GpgExe      = $GpgExe
        HostKeyPath = $HostKeyPath
        RepoRoot    = $RepoRoot
        OutputPath  = $outputPath
        SopsExe     = $SopsExe
      }
      if (-not [string]::IsNullOrWhiteSpace($PrimarySshKeyPath)) {
        $getDecryptedBlobParams['PrimarySshKeyPath'] = $PrimarySshKeyPath
      }
      Get-DecryptedBlob @getDecryptedBlobParams

      if (Test-Path -LiteralPath $outputPath) {
        $decryptedWallpaper = Get-Item -LiteralPath $outputPath -Force
        $decryptedWallpaper.Attributes = $decryptedWallpaper.Attributes -bor [System.IO.FileAttributes]::ReadOnly
      }

      if (-not $activeWallpaperPath) {
        $activeWallpaperPath = $outputPath
      }
    }

    foreach ($fileName in $unencryptedFiles) {
      $outputPath = Join-Path -Path $outputDir -ChildPath $fileName
      Write-Output "$($PSStyle.Foreground.Cyan)Linking unencrypted wallpaper for $user`: $fileName$($PSStyle.Reset)"
      $null = Deploy-UserWritableSymlink `
        -Name "wallpaper-$fileName" `
        -User $user `
        -ConfigName 'wallpapers' `
        -RelativePath "wallpapers/$fileName" `
        -RepoRoot $RepoRoot `
        -TargetPath $outputPath
      if (Test-Path -LiteralPath $outputPath) {
        Set-ManagedSymlinkDeleteProtection -Context 'Sync-WallpaperInventory' -Path $outputPath
        if (-not $activeWallpaperPath) {
          $activeWallpaperPath = $outputPath
        }
      }
    }
  }

  if (-not $activeWallpaperPath) {
    Write-Output "$($PSStyle.Foreground.Yellow)No overlay wallpaper sources found for specified users; skipping wallpaper sync.$($PSStyle.Reset)"
    return $null
  }

  Write-Output "$($PSStyle.Foreground.Green)Wallpaper sync complete.$($PSStyle.Reset)"
  return $activeWallpaperPath
}
