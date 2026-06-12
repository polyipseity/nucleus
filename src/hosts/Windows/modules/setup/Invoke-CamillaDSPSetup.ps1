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
      $installedVersion = & $binaryPath --version 2>$null
      if ($LASTEXITCODE -eq 0 -and $installedVersion -match "CamillaDSP (\S+)") {
        $installedVersion = $matches[1]
        if ($installedVersion -eq $desiredVersion) {
          $alreadyConverged = $true
        }
      }
    } catch {
      # Binary exists but is broken — will reinstall.
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
    New-Item -ItemType Directory -Force -Path $tempDir | Out-Null

    Write-Output "camilladsp-setup: downloading v${desiredVersion} from GitHub releases"
    # -ErrorAction SilentlyContinue is intentional: download failure is a
    # runtime probe — the if-guard above checks for the binary next.
    Invoke-WebRequest -Uri $zipUrl -OutFile $zipPath -ErrorAction SilentlyContinue
    if (-not (Test-Path $zipPath)) {
      Write-Error "camilladsp-setup: download failed from $zipUrl"
      return
    }

    Write-Output "camilladsp-setup: extracting camilladsp.exe"
    # Ensure install directory exists.
    New-Item -ItemType Directory -Force -Path $installDir | Out-Null

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

    # Ensure install directory is on PATH for future sessions.
    $userPath = [Environment]::GetEnvironmentVariable("PATH", "User")
    if ($userPath -notlike "*$installDir*") {
      $newPath = if ($userPath) { "$installDir;$userPath" } else { $installDir }
      [Environment]::SetEnvironmentVariable("PATH", $newPath, "User")
      Write-Output "camilladsp-setup: added $installDir to user PATH"
    }
    # Also update session-level PATH so the binary is immediately available.
    if ($env:PATH -notlike "*$installDir*") {
      $env:PATH = "$installDir;$env:PATH"
    }
  } finally {
    # Clean up temp directory.
    if (Test-Path $tempDir) {
      Remove-Item -Recurse -Force $tempDir
    }
  }
}
