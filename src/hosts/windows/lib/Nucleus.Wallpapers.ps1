function Sync-NucleusWallpapers {
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
    return
  }

  $wallpaperFiles = @(Get-ChildItem -Path $AssetsDir -Filter "*.sops" | Sort-Object Name)
  if ($wallpaperFiles.Count -eq 0) {
    Write-Host "No wallpaper blobs (*.sops) found in $AssetsDir; skipping wallpaper sync." -ForegroundColor Yellow
    return
  }

  if (-not (Test-Path -Path $OutputDir)) {
    New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
  }

  foreach ($wallpaperFile in $wallpaperFiles) {
    $outputName = [System.IO.Path]::GetFileNameWithoutExtension($wallpaperFile.Name)
    $outputPath = Join-Path -Path $OutputDir -ChildPath $outputName

    Write-Host "Materializing wallpaper: $outputName" -ForegroundColor Cyan
    Get-NucleusDecryptedBlob -FilePath $wallpaperFile.FullName -GpgExe $GpgExe -HostKeyPath $HostKeyPath -OutputPath $outputPath -SopsExe $SopsExe
  }

  Write-Host "Wallpaper sync complete." -ForegroundColor Green
}
