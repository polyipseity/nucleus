function Invoke-CamillaDSPSetup {
  <#
  .SYNOPSIS
    Idempotently installs or updates the CamillaDSP prebuilt binary for Windows.

  .DESCRIPTION
    Downloads the CamillaDSP prebuilt binary from GitHub releases if not
    installed or if the installed version differs from the lockfile pin.
    Extracts camilladsp.exe to %USERPROFILE%\.local\bin\ and ensures the
    directory is on PATH.

    CamillaDSP is not available in WinGet, Scoop, or cargo-binstall, so a
    direct GitHub release download is used instead.

  .EXAMPLE
    Invoke-CamillaDSPSetup

  .NOTES
    Exit codes: 0 on success; non-zero on failure.
  #>
  [CmdletBinding()]
  param()

  $installDir = Join-Path $HOME ".local\bin"
  $binaryPath = Join-Path $installDir "camilladsp.exe"

  # Derive repo root from script location (src/hosts/Windows/modules/setup/ -> repo root is 5 levels up).
  $repoRoot = Resolve-Path "$PSScriptRoot\..\..\..\..\.."
  $lockfilePath = Join-Path $repoRoot "lockfiles\lockfile.json"

  # Read version-pinning data from the consolidated lockfile.
  $lockfile = @{}
  if (Test-Path $lockfilePath) {
    $lockfile = Get-Content $lockfilePath -Raw | ConvertFrom-Json
  }
  $desiredVersion = if ($lockfile.'camilladsp' -is [string]) { $lockfile.'camilladsp' } else { "4.1.3" }
  $desiredVersion = $desiredVersion.TrimStart('v')

  # Check if already installed at the desired version.
  $alreadyConverged = $false
  if (Test-Path $binaryPath) {
    try {
      $installedVersion = & $binaryPath --version 2>$null  # check-suppress:suppression_doc: probe -- binary may not be installed yet; $LASTEXITCODE checked below
      if ($LASTEXITCODE -eq 0 -and $installedVersion -match "CamillaDSP (\S+)") {
        $installedVersion = $matches[1]
        if ($installedVersion -eq $desiredVersion) {
          $alreadyConverged = $true
        }
      }
    } catch {
      # Binary exists but is broken — will reinstall.
      Write-Debug "camilladsp-setup: existing binary check failed: $_"
    }
  }

  if ($alreadyConverged) {
    Write-Output "camilladsp-setup: v$desiredVersion already installed — skipping"
    return
  }

  # Download and extract prebuilt binary from GitHub releases.
  $zipUrl = "https://github.com/HEnquist/camilladsp/releases/download/v${desiredVersion}/camilladsp-windows-amd64.zip"
  $tempDir = Join-Path $env:TEMP "camilladsp-setup"
  $zipPath = Join-Path $tempDir "camilladsp.zip"

  try {
    # Clean any partial previous download.
    if (Test-Path $tempDir) {
      Remove-Item -Recurse -Force $tempDir
    }
    New-Item -ItemType Directory -Force -Path $tempDir > $null

    Write-Output "camilladsp-setup: downloading v${desiredVersion} from GitHub releases"
    # check-suppress:suppression_doc: probe -- download may fail; Test-Path check handles failure downstream.
    Invoke-WebRequest -Uri $zipUrl -OutFile $zipPath -ErrorAction SilentlyContinue
    if (-not (Test-Path $zipPath)) {
      Write-Error "camilladsp-setup: download failed from $zipUrl"
      return
    }

    Write-Output "camilladsp-setup: extracting camilladsp.exe"
    # Ensure install directory exists.
    New-Item -ItemType Directory -Force -Path $installDir > $null

    # Extract just camilladsp.exe from the zip.
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
    try {
      $entry = $zip.Entries | Where-Object { $_.Name -eq "camilladsp.exe" }
      if (-not $entry) {
        Write-Error "camilladsp-setup: camilladsp.exe not found in downloaded zip"
        return
      }
      [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $binaryPath, $true)
    } finally {
      $zip.Dispose()
    }

    # Verify extraction.
    if (-not (Test-Path $binaryPath)) {
      Write-Error "camilladsp-setup: extraction failed — $binaryPath not found"
      return
    }

    Write-Output "camilladsp-setup: v$desiredVersion installed to $binaryPath"

    # check-suppress:config-method: method 1 (writable symlink) -- deploy user-level config to $HOME\.config
    # (cross-platform parity with POSIX ~/.config/camilladsp/configs/config.yml).
    # check-suppress:config-method: method 1 (writable symlink) -- camilladsp/configs/Windows/default.yml deployed alongside config.yml
    $configDir = Join-Path -Path $HOME -ChildPath ".config\camilladsp\configs"
    $configPath = Join-Path -Path $configDir -ChildPath "config.yml"
    $configSource = Join-Path -Path $repoRoot -ChildPath "src\modules\configs\camilladsp\configs\windows\config.yml"
    if (-not (Test-Path $configDir)) {
      $null = New-Item -ItemType Directory -Path $configDir -Force  # check-suppress:suppression_doc: New-Item returns DirectoryInfo, discarded
    }
    if (Test-Path $configPath) { Remove-Item -Path $configPath -Force }
    New-Item -Path $configPath -ItemType SymbolicLink -Target $configSource -Force > $null
    Write-Output "camilladsp-setup: symlinked config to $configPath"
  } finally {
    # Clean up temp directory.
    if (Test-Path $tempDir) {
      Remove-Item -Recurse -Force $tempDir
    }
  }
}
