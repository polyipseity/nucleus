function Invoke-SourceBuild {
  <#
  .SYNOPSIS
    Idempotently converges declarative source-built packages (git clone +
    build system) for the Windows host.

  .DESCRIPTION
    Reads the source-builds package registry (source-builds.json) and the
    repository lockfile for VCS hash pins, then ensures each package is
    built and installed at the pinned revision.  On each apply it:

      1. Checks the install cache for each package at the pinned revision.
      2. Clones or fetches the git repository at the pinned commit.
      3. Invokes the build system (currently only 'zig').
      4. Copies the built binary to the install directory.
      5. Prepends the install directory to PATH.

    Packages absent from the registry are pruned from the install root
    (zap-style).  Build-time dependencies (e.g. zig) must be installed
    beforehand by Invoke-ScoopSetup.

    Mirrors the declarative mkDerivation pattern from nixpkgs for the
    Windows host, using a JSON registry + VCS hash pins in lockfile.json
    instead of a Nix expression.

  .EXAMPLE
    Invoke-SourceBuild

  .NOTES
    Environment variables: (none)
    Exit codes: 0 on success; non-zero on failure.
  #>
  [CmdletBinding()]
  param()

  # Derive repo root from script location (src/hosts/Windows/modules/setup/ -> repo root is 5 levels up).
  $repoRoot = Resolve-Path "$PSScriptRoot\..\..\..\..\.."
  $lockfilePath = Join-Path $repoRoot "lockfiles\lockfile.json"
  $registryPath = Resolve-Path "$PSScriptRoot\..\source-builds.json"

  # Install root for source-built packages.
  $installRoot = Join-Path $env:USERPROFILE "source-builds"
  # Cache root for cloned repositories (avoids re-cloning on every apply).
  $cacheRoot = Join-Path $env:USERPROFILE "source-builds\.cache"

  # Guard: registry must exist.
  if (-not (Test-Path $registryPath)) {
    Write-Error "Invoke-SourceBuild: registry not found at '$registryPath'"
    return
  }

  # Read the package registry.
  $registry = Get-Content $registryPath -Raw | ConvertFrom-Json

  # Read version-pinning data from the consolidated lockfile.
  $lockfile = @{}
  if (Test-Path $lockfilePath) {
    $lockfile = Get-Content $lockfilePath -Raw | ConvertFrom-Json
  }
  $sourceBuildPins = if ($lockfile -and $lockfile.'source-builds') { $lockfile.'source-builds' } else { @{} }

  # --- Prune: remove installed packages absent from registry ---
  if (Test-Path $installRoot) {
    $installedDirs = Get-ChildItem -Directory $installRoot | ForEach-Object { $_.Name }
    $registryIds = @{}; foreach ($pkg in $registry.packages) { $registryIds[$pkg.id] = $true }
    foreach ($dirName in $installedDirs) {
      if ($dirName -eq '.cache') { continue } # skip cache directory itself
      if (-not $registryIds.ContainsKey($dirName)) {
        $target = Join-Path $installRoot $dirName
        Write-Output "Invoke-SourceBuild: pruning absent package '$dirName' at '$target'"
        Remove-Item -Recurse -Force $target -ErrorAction Stop
      }
    }
  }

  # --- Build / install each registry package ---
  foreach ($pkg in $registry.packages) {
    $pkgId = $pkg.id
    $pin = $sourceBuildPins.$pkgId

    if (-not $pin) {
      Write-Warning "Invoke-SourceBuild: no lockfile pin for '$pkgId'; skipping build (add to lockfile.json source-builds)"
      continue
    }

    $rev = $pin.rev
    $sourceUrl = $pin.source
    $version = if ($pin.version) { $pin.version } else { $rev }
    $binaryName = $pkg.binaryName
    $binarySubDir = $pkg.binarySubDir
    $buildSystem = $pkg.buildSystem
    $installDir = Join-Path $installRoot $pkg.installDir
    $binaryPath = Join-Path $installDir $binaryName
    $checkArgs = $pkg.checkVersionArgs
    $checkPattern = $pkg.checkVersionPattern
    $deps = $pkg.dependencies

    # --- Dependency guard ---
    $missingDep = $false
    foreach ($dep in $deps) {
      # undoc-supp: probe — build dependency may not be installed; if-guard checks absence below.
      if (-not (Get-Command $dep -ErrorAction SilentlyContinue)) {
        Write-Warning "Invoke-SourceBuild: missing build dependency '$dep' for '$pkgId'; skipping. Ensure $dep is installed via Scoop before calling Invoke-SourceBuild."
        $missingDep = $true
        break
      }
    }
    if ($missingDep) { continue }

    # --- Check if already installed at correct revision ---
    $markerPath = Join-Path $installDir ".sourcebuild-rev"
    $alreadyInstalled = $false
    if (Test-Path $markerPath) {
      $installedRev = Get-Content $markerPath -Raw | ForEach-Object { $_.Trim() }
      if ($installedRev -eq $rev) {
        # Also verify the binary exists and produces a plausible version string.
        if (Test-Path $binaryPath) {
          try {
            $versionOutput = & $binaryPath $checkArgs 2>&1 | Out-String
            if ($versionOutput -match $checkPattern) {
              $alreadyInstalled = $true
            }
          } catch {
            # Binary exists but is broken; rebuild.
            Write-Debug "Invoke-SourceBuild: existing binary check failed for '$pkgId': $_"
          }
        }
      }
    }

    if ($alreadyInstalled) {
      Write-Output "Invoke-SourceBuild: '$pkgId' v$version already installed at '$installDir'"
      continue
    }

    # --- Clone / fetch the repository ---
    $repoCacheDir = Join-Path $cacheRoot $pkgId
    if (-not (Test-Path $repoCacheDir)) {
      Write-Output "Invoke-SourceBuild: cloning $pkgId from $sourceUrl"
      $null = New-Item -ItemType Directory -Path $repoCacheDir -Force -ErrorAction Stop
      & git clone $sourceUrl $repoCacheDir 2>&1 | Out-Null
      if ($LASTEXITCODE -ne 0) {
        Write-Error "Invoke-SourceBuild: git clone failed for '$pkgId'"
        continue
      }
    }

    # Fetch and checkout the pinned revision.
    Push-Location $repoCacheDir
    try {
      # Fetch the specific revision (works for both tags and commits).
      & git fetch origin '+refs/*:refs/*' 2>&1 | Out-Null
      & git checkout $rev 2>&1 | Out-Null
      if ($LASTEXITCODE -ne 0) {
        Write-Error "Invoke-SourceBuild: git checkout $rev failed for '$pkgId'"
        continue
      }
    } finally {
      Pop-Location
    }

    # --- Build ---
    Write-Output "Invoke-SourceBuild: building $pkgId v$version with $buildSystem"
    Push-Location $repoCacheDir
    try {
      switch ($buildSystem) {
        'zig' {
          & zig build 2>&1 | Out-String -Width 4096 | ForEach-Object { Write-Verbose $_ }
          if ($LASTEXITCODE -ne 0) {
            Write-Error "Invoke-SourceBuild: zig build failed for '$pkgId'"
            continue
          }
        }
        default {
          Write-Error "Invoke-SourceBuild: unsupported build system '$buildSystem' for '$pkgId'"
          continue
        }
      }
    } finally {
      Pop-Location
    }

    # --- Install binary ---
    $builtBinary = Join-Path $repoCacheDir $binarySubDir $binaryName
    if (-not (Test-Path $builtBinary)) {
      Write-Error "Invoke-SourceBuild: built binary not found at '$builtBinary' for '$pkgId'"
      continue
    }

    $null = New-Item -ItemType Directory -Path $installDir -Force -ErrorAction Stop
    Copy-Item $builtBinary $installDir -Force -ErrorAction Stop
    Set-Content -Path $markerPath -Value $rev -Force -ErrorAction Stop
    Write-Output "Invoke-SourceBuild: installed $pkgId v$version to '$installDir'"
  }

  # --- Update PATH for this session ---
  $pathsToAdd = @()
  if (Test-Path $installRoot) {
    $installedDirs = Get-ChildItem -Directory $installRoot | ForEach-Object { $_.Name } | Where-Object { $_ -ne '.cache' }
    foreach ($dirName in $installedDirs) {
      $dir = Join-Path $installRoot $dirName
      if ($env:PATH -notlike "*$dir*") {
        $pathsToAdd += $dir
      }
    }
  }
  if ($pathsToAdd.Count -gt 0) {
    $env:PATH = "$($pathsToAdd -join ';');$env:PATH"
    Write-Output "Invoke-SourceBuild: prepended to PATH: $($pathsToAdd -join ', ')"
  }
}
