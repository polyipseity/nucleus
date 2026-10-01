function Invoke-CamillaGUISetup {
  <#
  .SYNOPSIS
    Idempotently installs or updates the camillagui-backend prebuilt bundle for
    Windows.

  .DESCRIPTION
    Downloads the camillagui-backend prebuilt bundle from GitHub releases when
    it is not installed or the installed version misses the lockfile pin, then
    extracts camillagui_backend into %USERPROFILE%\.local\bin\ and puts it on
    PATH.

    WHY a direct release download: camillagui-backend is in neither WinGet,
    Scoop, nor cargo-binstall.
  #>
  [CmdletBinding()]
  param()

  $installDir = Join-Path $HOME ".local\bin\camillagui_backend"
  $binaryPath = Join-Path $installDir "camillagui_backend.exe"

  $repoRoot = Resolve-Path "$PSScriptRoot\..\..\..\..\.."
  $lockfilePath = Join-Path $repoRoot "src\lockfiles\lockfile.json"

  $lockfile = @{}
  if (Test-Path $lockfilePath) {
    $lockfile = Get-Content $lockfilePath -Raw | ConvertFrom-Json
  }
  $desiredVersion = if ($lockfile.'camillagui-backend' -is [string]) { $lockfile.'camillagui-backend' } else { "4.1.0" }
  $desiredVersion = $desiredVersion.TrimStart('v')

  $alreadyConverged = $false
  if (Test-Path $binaryPath) {
    $alreadyConverged = $true
  }

  if ($alreadyConverged) {
    Write-NucleusInfo -CommandName 'camillagui-backend-setup' "v$desiredVersion already installed — skipping"
    return
  }

  $zipUrl = "https://github.com/HEnquist/camillagui-backend/releases/download/v${desiredVersion}/bundle_windows_amd64.zip"
  $tempDir = Join-Path $env:TEMP "camillagui-backend-setup"
  $zipPath = Join-Path $tempDir "camillagui-backend.zip"

  try {
    # drop any partial previous download
    if (Test-Path $tempDir) {
      Remove-Item -Recurse -Force $tempDir
    }
    New-Item -ItemType Directory -Force -Path $tempDir > $null

    Write-NucleusInfo -CommandName 'camillagui-backend-setup' "downloading v${desiredVersion} from GitHub releases"
    # check-suppress:suppression_doc: probe -- download may fail; Test-Path check handles failure downstream.
    Invoke-WebRequest -Uri $zipUrl -OutFile $zipPath -ErrorAction SilentlyContinue
    if (-not (Test-Path $zipPath)) {
      Write-NucleusError -CommandName 'camillagui-backend-setup' "download failed from $zipUrl"
      return
    }

    Write-NucleusInfo -CommandName 'camillagui-backend-setup' "extracting to $installDir"
    # parent directory may not exist yet
    $parentDir = Split-Path $installDir -Parent
    New-Item -ItemType Directory -Force -Path $parentDir > $null

    # Extract the full camillagui_backend directory from the zip.
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
    try {
      # remove the old install first so stale files cannot survive
      if (Test-Path $installDir) {
        Remove-Item -Recurse -Force $installDir
      }
      # only entries under the camillagui_backend/ prefix
      $entries = $zip.Entries | Where-Object { $_.FullName -like "camillagui_backend/*" -and $_.Name -ne "" }
      foreach ($entry in $entries) {
        $relativePath = $entry.FullName.Substring("camillagui_backend/".Length)
        $targetPath = Join-Path $installDir $relativePath
        $targetDir = Split-Path $targetPath -Parent
        if (-not (Test-Path $targetDir)) {
          New-Item -ItemType Directory -Force -Path $targetDir > $null
        }
        [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $targetPath, $true)
      }
    } finally {
      $zip.Dispose()
    }

    # verify the extraction
    if (-not (Test-Path $binaryPath)) {
      Write-NucleusError -CommandName 'camillagui-backend-setup' "extraction failed — $binaryPath not found"
      return
    }

    Write-NucleusInfo -CommandName 'camillagui-backend-setup' "v$desiredVersion installed to $installDir"

    # check-suppress:config-method: method 1 (writable symlink) -- deploy user-level config to $HOME\.config
    # (cross-platform parity with POSIX ~/.config/camillagui-backend/config.yml).
    $configDir = Join-Path -Path $HOME -ChildPath ".config\camillagui-backend"
    $configPath = Join-Path -Path $configDir -ChildPath "config.yml"
    $configSource = Join-Path -Path $repoRoot -ChildPath "src\modules\configs\camillagui-backend\config-Windows.yml"  # check-suppress:config-method: method 1 (writable symlink)
    if (-not (Test-Path $configDir)) {
      $null = New-Item -ItemType Directory -Path $configDir -Force  # check-suppress:suppression_doc: New-Item returns DirectoryInfo, discarded
    }
    if (Test-Path $configPath) { Remove-Item -Path $configPath -Force }
    New-Item -Path $configPath -ItemType SymbolicLink -Target $configSource -Force > $null
    Write-NucleusInfo -CommandName 'camillagui-backend-setup' "symlinked config to $configPath"
  } finally {
    # drop the temp directory
    if (Test-Path $tempDir) {
      Remove-Item -Recurse -Force $tempDir
    }
  }
}
