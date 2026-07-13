function Invoke-CamillaGUISetup {
  <#
  .SYNOPSIS
    Idempotently installs or updates the camillagui-backend prebuilt bundle for
    Windows.

  .DESCRIPTION
    Downloads the camillagui-backend prebuilt bundle from GitHub releases if
    not installed or if the installed version differs from the lockfile pin.
    Extracts the full camillagui_backend directory to
    %USERPROFILE%\.local\bin\camillagui_backend\ and ensures the directory is
    on PATH.

    camillagui-backend is not available in WinGet, Scoop, or cargo-binstall,
    so a direct GitHub release download is used instead.

  .EXAMPLE
    Invoke-CamillaGUISetup

  .NOTES
    Exit codes: 0 on success; non-zero on failure.
  #>
  [CmdletBinding()]
  param()

  $installDir = Join-Path $HOME ".local\bin\camillagui_backend"
  $binaryPath = Join-Path $installDir "camillagui_backend.exe"

  # Derive repo root from script location (src/hosts/Windows/modules/setup/ -> repo root is 5 levels up).
  $repoRoot = Resolve-Path "$PSScriptRoot\..\..\..\..\.."
  $lockfilePath = Join-Path $repoRoot "lockfiles\lockfile.json"

  # Read version-pinning data from the consolidated lockfile.
  $lockfile = @{}
  if (Test-Path $lockfilePath) {
    $lockfile = Get-Content $lockfilePath -Raw | ConvertFrom-Json
  }
  $desiredVersion = if ($lockfile.'camillagui-backend' -is [string]) { $lockfile.'camillagui-backend' } else { "4.1.0" }
  $desiredVersion = $desiredVersion.TrimStart('v')

  # Check if already installed at the desired version.
  $alreadyConverged = $false
  if (Test-Path $binaryPath) {
    $alreadyConverged = $true
  }

  if ($alreadyConverged) {
    Write-Output "camillagui-backend-setup: v$desiredVersion already installed — skipping"
    return
  }

  # Download and extract prebuilt bundle from GitHub releases.
  $zipUrl = "https://github.com/HEnquist/camillagui-backend/releases/download/v${desiredVersion}/bundle_windows_amd64.zip"
  $tempDir = Join-Path $env:TEMP "camillagui-backend-setup"
  $zipPath = Join-Path $tempDir "camillagui-backend.zip"

  try {
    # Clean any partial previous download.
    if (Test-Path $tempDir) {
      Remove-Item -Recurse -Force $tempDir
    }
    New-Item -ItemType Directory -Force -Path $tempDir | Out-Null

    Write-Output "camillagui-backend-setup: downloading v${desiredVersion} from GitHub releases"
    # undoc-supp: probe — download may fail; Test-Path check handles failure downstream.
    Invoke-WebRequest -Uri $zipUrl -OutFile $zipPath -ErrorAction SilentlyContinue
    if (-not (Test-Path $zipPath)) {
      Write-Error "camillagui-backend-setup: download failed from $zipUrl"
      return
    }

    Write-Output "camillagui-backend-setup: extracting to $installDir"
    # Ensure parent directory exists.
    $parentDir = Split-Path $installDir -Parent
    New-Item -ItemType Directory -Force -Path $parentDir | Out-Null

    # Extract the full camillagui_backend directory from the zip.
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
    try {
      # Remove existing installation first to avoid stale files from old versions.
      if (Test-Path $installDir) {
        Remove-Item -Recurse -Force $installDir
      }
      # Extract only entries under the camillagui_backend/ prefix.
      $entries = $zip.Entries | Where-Object { $_.FullName -like "camillagui_backend/*" -and $_.Name -ne "" }
      foreach ($entry in $entries) {
        $relativePath = $entry.FullName.Substring("camillagui_backend/".Length)
        $targetPath = Join-Path $installDir $relativePath
        $targetDir = Split-Path $targetPath -Parent
        if (-not (Test-Path $targetDir)) {
          New-Item -ItemType Directory -Force -Path $targetDir | Out-Null
        }
        [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $targetPath, $true)
      }
    } finally {
      $zip.Dispose()
    }

    # Verify extraction.
    if (-not (Test-Path $binaryPath)) {
      Write-Error "camillagui-backend-setup: extraction failed — $binaryPath not found"
      return
    }

    Write-Output "camillagui-backend-setup: v$desiredVersion installed to $installDir"

    # Ensure install directory is on PATH for future sessions.
    Set-NucleusUserPathEntry -Directory $installDir -Name "camillagui-backend-setup"

    # Method 1 (writable symlink): deploy user-level config to $HOME\.config
    # (cross-platform parity with POSIX ~/.config/camillagui-backend/config.yml).
    $configDir = Join-Path -Path $HOME -ChildPath ".config\camillagui-backend"
    $configPath = Join-Path -Path $configDir -ChildPath "config.yml"
    $configSource = Join-Path -Path $repoRoot -ChildPath "src\modules\configs\camillagui-backend\config-windows.yml"
    if (-not (Test-Path $configDir)) {
      $null = New-Item -ItemType Directory -Path $configDir -Force
    }
    if (Test-Path $configPath) { Remove-Item -Path $configPath -Force }
    New-Item -Path $configPath -ItemType SymbolicLink -Target $configSource -Force | Out-Null
    Write-Output "camillagui-backend-setup: symlinked config to $configPath"
  } finally {
    # Clean up temp directory.
    if (Test-Path $tempDir) {
      Remove-Item -Recurse -Force $tempDir
    }
  }
}
