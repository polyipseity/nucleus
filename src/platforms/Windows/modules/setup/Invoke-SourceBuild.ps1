function Invoke-SourceBuild {
  <#
  .SYNOPSIS
    Idempotently converges declarative source-built packages (git clone +
    build system) for the Windows host.

  .DESCRIPTION
    Reads the source-builds registry and the lockfile VCS pins, then ensures
    each package is built at the pinned revision: clone or fetch, run the build
    system, copy the binary into the install root.

    Packages absent from the registry are pruned from the install root.
    Build-time dependencies such as zig come from Invoke-ScoopSetup.

  .NOTES
    Environment variables: (none)
    Exit codes: 0 on success; non-zero on failure.
  #>
  [CmdletBinding()]
  param()

  # 5 levels up from src/platforms/Windows/modules/setup/ is the repo root.
  $repoRoot = Resolve-Path "$PSScriptRoot\..\..\..\..\.."
  $lockfilePath = Join-Path $repoRoot "src\lockfiles\lockfile.json"
  $registryPath = Resolve-Path "$PSScriptRoot\..\source-builds.json"

  $installRoot = Join-Path $env:USERPROFILE "source-builds"
  $cacheRoot = Join-Path $env:USERPROFILE "source-builds\.cache"

  if (-not (Test-Path $registryPath)) {
    Write-NucleusError -CommandName 'Invoke-SourceBuild' "registry not found at '$registryPath'"
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

  # Prune: remove installed packages absent from registry
  if (Test-Path $installRoot) {
    $installedDirs = Get-ChildItem -Directory $installRoot | ForEach-Object { $_.Name }
    $registryIds = @{}; foreach ($pkg in $registry.packages) { $registryIds[$pkg.id] = $true }
    foreach ($dirName in $installedDirs) {
      if ($dirName -eq '.cache') { continue } # skip cache directory itself
      if (-not $registryIds.ContainsKey($dirName)) {
        $target = Join-Path $installRoot $dirName
        Write-NucleusInfo -CommandName 'Invoke-SourceBuild' "pruning absent package '$dirName' at '$target'"
        Remove-Item -Recurse -Force $target -ErrorAction Stop
      }
    }
  }

  # Build / install each registry package
  foreach ($pkg in $registry.packages) {
    $pkgId = $pkg.id
    $pin = $sourceBuildPins.$pkgId

    if (-not $pin) {
      Write-NucleusWarning -CommandName 'Invoke-SourceBuild' "no lockfile pin for '$pkgId'; skipping build (add to lockfile.json source-builds)"
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

    # Dependency guard
    $missingDep = $false
    foreach ($dep in $deps) {
      # check-suppress:suppression_doc: probe -- build dependency may not be installed; if-guard checks absence below.
      if (-not (Get-Command $dep -ErrorAction SilentlyContinue)) {
        Write-NucleusWarning -CommandName 'Invoke-SourceBuild' "missing build dependency '$dep' for '$pkgId'; skipping. Ensure $dep is installed via Scoop before calling Invoke-SourceBuild."
        $missingDep = $true
        break
      }
    }
    if ($missingDep) { continue }

    # Already installed at the correct revision?
    $markerPath = Join-Path $installDir ".sourcebuild-rev"
    $alreadyInstalled = $false
    if (Test-Path $markerPath) {
      $installedRev = Get-Content $markerPath -Raw | ForEach-Object { $_.Trim() }
      if ($installedRev -eq $rev) {
        # Also verify the binary exists and reports a plausible version string.
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
      Write-NucleusInfo -CommandName 'Invoke-SourceBuild' "'$pkgId' v$version already installed at '$installDir'"
      continue
    }

    # Clone / fetch the repository
    $repoCacheDir = Join-Path $cacheRoot $pkgId
    if (-not (Test-Path $repoCacheDir)) {
      Write-NucleusInfo -CommandName 'Invoke-SourceBuild' "cloning $pkgId from $sourceUrl"
      $null = New-Item -ItemType Directory -Path $repoCacheDir -Force -ErrorAction Stop  # check-suppress:suppression_doc: New-Item returns DirectoryInfo, discarded
      & git clone $sourceUrl $repoCacheDir 2>&1 > $null
      if ($LASTEXITCODE -ne 0) {
        Write-NucleusError -CommandName 'Invoke-SourceBuild' "git clone failed for '$pkgId'"
        continue
      }
    }

    # Fetch and checkout the pinned revision (tag or commit).
    Push-Location $repoCacheDir
    try {
      # Fetch the specific revision (works for both tags and commits).
      & git fetch origin '+refs/*:refs/*' 2>&1 > $null
      & git checkout $rev 2>&1 > $null
      if ($LASTEXITCODE -ne 0) {
        Write-NucleusError -CommandName 'Invoke-SourceBuild' "git checkout $rev failed for '$pkgId'"
        continue
      }
    } finally {
      Pop-Location
    }

    # Build
    Write-NucleusInfo -CommandName 'Invoke-SourceBuild' "building $pkgId v$version with $buildSystem"
    Push-Location $repoCacheDir
    try {
      switch ($buildSystem) {
        'zig' {
          & zig build 2>&1 | Out-String -Width 4096 | ForEach-Object { Write-Verbose $_ }
          if ($LASTEXITCODE -ne 0) {
            Write-NucleusError -CommandName 'Invoke-SourceBuild' "zig build failed for '$pkgId'"
            continue
          }
        }
        default {
          Write-NucleusError -CommandName 'Invoke-SourceBuild' "unsupported build system '$buildSystem' for '$pkgId'"
          continue
        }
      }
    } finally {
      Pop-Location
    }

    # Install binary
    $builtBinary = Join-Path -Path $repoCacheDir -ChildPath $binarySubDir -AdditionalChildPath $binaryName
    if (-not (Test-Path $builtBinary)) {
      Write-NucleusError -CommandName 'Invoke-SourceBuild' "built binary not found at '$builtBinary' for '$pkgId'"
      continue
    }

    $null = New-Item -ItemType Directory -Path $installDir -Force -ErrorAction Stop  # check-suppress:suppression_doc: New-Item returns DirectoryInfo, discarded
    Copy-Item $builtBinary $installDir -Force -ErrorAction Stop
    Set-Content -Path $markerPath -Value $rev -Force -ErrorAction Stop
    Write-NucleusInfo -CommandName 'Invoke-SourceBuild' "installed $pkgId v$version to '$installDir'"
  }

  # Update PATH for this session
  if (Test-Path $installRoot) {
    $installedDirs = Get-ChildItem -Directory $installRoot | ForEach-Object { $_.Name } | Where-Object { $_ -ne '.cache' }
    foreach ($dirName in $installedDirs) {
      $dir = Join-Path $installRoot $dirName
      Add-NucleusPathEntry -Path $dir
    }
  }
}
