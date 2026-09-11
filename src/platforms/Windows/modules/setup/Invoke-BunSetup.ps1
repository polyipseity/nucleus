function Invoke-BunSetup {
  <#
  .SYNOPSIS
    Idempotently converges the declarative bun global package set.

  .DESCRIPTION
    Maintains a managed set of JS CLI tools installed via `bun install -g`.
    On each apply it queries bun's global package.json for the actually
    installed set, removes anything installed but absent from the desired list
    (zap-style, mirroring homebrew's cleanup = "zap"), and installs any
    desired packages that are missing at versions pinned in the repository
    lockfile.

    Only packages absent from WinGet, Scoop, and cargo-binstall are managed
    here, following the repository preference hierarchy
    (nixpkgs/winget > scoop > cargo binstall > cargo > bun > uv).

    The desired set and the per-package rationale live in the shared registry
    src/modules/packages/desired.json (bun -> <host>); each entry may carry a
    "binary" override naming the installed executable when it differs from the
    unscoped package basename.

    Requires bun to be on PATH (installed from WinGet by system/packages.dsc.yml).
    Prepends %USERPROFILE%\.bun\bin to PATH internally so bun-installed
    binaries are accessible in subsequent steps of the same apply session.

  .EXAMPLE
    Invoke-BunSetup

  .NOTES
    Environment variables: (none)
    Exit codes: 0 on success; non-zero on failure.
  #>
  [CmdletBinding()]
  param()

  # Derive repo root from script location (src/platforms/Windows/modules/setup/ -> repo root is 5 levels up).
  $repoRoot = Resolve-Path "$PSScriptRoot\..\..\..\..\.."
  $lockfilePath = Join-Path $repoRoot "src\lockfiles\lockfile.json"

  # Get-NucleusHostKey resolves the canonical host key used to slice the shared
  # desired-package registry.
  . (Join-Path -Path $repoRoot -ChildPath "src\platforms\Windows\modules\Get-NucleusHostPlatform.ps1")

  # Read version-pinning data from the consolidated lockfile.
  $lockfile = @{}
  if (Test-Path $lockfilePath) {
    $lockfile = Get-Content $lockfilePath -Raw | ConvertFrom-Json
  }
  $bunVersions = if ($lockfile -and $lockfile.bun) { $lockfile.bun } else { @{} }

  # Declarative desired-state list from the shared registry (single source of
  # truth: src/modules/packages/desired.json).  Entries are objects; an entry's
  # "binary" names the installed executable when it differs from the unscoped
  # package basename (e.g. @anthropic-ai/sandbox-runtime installs 'srt').
  $desiredPath = Join-Path $repoRoot "src\modules\packages\desired.json"
  if (-not (Test-Path -LiteralPath $desiredPath)) {
    Write-NucleusError -CommandName 'Invoke-BunSetup' "desired package registry not found at '$desiredPath'"
    return
  }
  $hostKey = Get-NucleusHostKey
  $hostDesired = (Get-Content -LiteralPath $desiredPath -Raw | ConvertFrom-Json).bun.$hostKey
  if ($null -eq $hostDesired) {
    Write-NucleusError -CommandName 'Invoke-BunSetup' "desired package registry has no bun list for host '$hostKey'"
    return
  }
  $desiredPackages = @($hostDesired | ForEach-Object { $_.name })
  $binaryNames = @{}
  foreach ($entry in $hostDesired) {
    if ($entry.binary) {
      $binaryNames[$entry.name] = $entry.binary
    }
  }

  # bun install -g places binaries in ~\.bun\bin by default (BUN_INSTALL_BIN).
  # Canonical source: ManagedPaths.ps1 -> managed-paths.nix (pathComponents).
  $bunBinDir = Get-NucleusManagedBinDir "bun"

  # Guard: bun must be accessible after WinGet DSC has installed Oven-sh.Bun.
  # check-suppress:suppression_doc: probe -- bun may not be installed; if-guard checks absence below.
  if (-not (Get-Command bun -ErrorAction SilentlyContinue)) {
    Write-NucleusError -CommandName 'Invoke-BunSetup' "bun not found on PATH; ensure Oven-sh.Bun was installed by WinGet DSC before calling this function"
    return
  }

  # Prepend ~/.bun/bin so binaries installed during this apply run are
  # accessible in subsequent steps without opening a new terminal session.
  if ($env:PATH -notlike "*$bunBinDir*") {
    $env:PATH = "$env:PATH;$bunBinDir"
  }

  # Get actually installed global packages from bun's authoritative package
  # registry (zap-style: remove any installed package absent from the desired
  # list, regardless of prior managed state).
  $bunGlobalJson = Join-Path $HOME ".bun\install\global\package.json"
  $installedPackages = @()
  $installedVersions = @{}
  if (Test-Path $bunGlobalJson) {
    try {
      $globalPkg = Get-Content -Path $bunGlobalJson -Raw | ConvertFrom-Json
      if ($null -ne $globalPkg -and $null -ne $globalPkg.dependencies) {
        $installedPackages = @($globalPkg.dependencies.PSObject.Properties.Name)
        foreach ($prop in $globalPkg.dependencies.PSObject.Properties) {
          $installedVersions[$prop.Name] = $prop.Value
        }
      }
    }
    catch {
      # || SilentlyContinue equivalent: parse failure treats installed set as
      # empty — safe because any desired packages will simply be re-installed.
      Write-NucleusWarning -CommandName 'Invoke-BunSetup' "could not parse '$bunGlobalJson'; treating as empty installed set"
    }
  }

  # Packages installed but not desired: zap-style removal.
  # Mirrors homebrew cleanup = "zap": removes anything installed but absent
  # from the declared desired set, regardless of how it was installed.
  $toRemove = @($installedPackages | Where-Object { $desiredPackages -notcontains $_ })

  # Desired packages not yet in bun's global package.json, or whose binary is
  # absent from ~\.bun\bin, or installed at a version different from the
  # lockfile pin (version-aware reconciliation).  Binary name = last path
  # component after '/' so @scope/name becomes name (bun uses the unscoped
  # name for the bin).
  $toInstall = @($desiredPackages | Where-Object {
    $pkg = $_
    $binName = if ($binaryNames.ContainsKey($pkg)) { $binaryNames[$pkg] } else { ($pkg -split '/')[-1] }
    $notInstalled = $installedPackages -notcontains $pkg
    $binMissing = -not (
      (Test-Path (Join-Path $bunBinDir $binName)) -or
      (Test-Path (Join-Path $bunBinDir "$binName.exe")) -or
      (Test-Path (Join-Path $bunBinDir "$binName.cmd"))
    )
    if ($notInstalled -or $binMissing) { return $true }
    $entry = $bunVersions.$pkg
    if ($entry -is [string]) {
      # Version-pinned entry: reinstall if version mismatch.
      if (-not $entry) { return $false }
      $installedVersion = $installedVersions[$pkg]
      return $installedVersion -ne $entry
    }
    # Hash-pinned entry (PSObject with .source/.rev): already installed, skip.
    return $false
  })

  foreach ($pkg in $toRemove) {
    Write-NucleusInfo -CommandName 'bun-setup' "removing $pkg"
    bun remove -g $pkg
    if ($LASTEXITCODE -ne 0) {
      Write-NucleusError -CommandName 'bun-setup' "'bun remove -g $pkg' failed (exit $LASTEXITCODE)"
      return
    }
    Write-NucleusInfo -CommandName 'bun-setup' "$pkg removed"
  }

  # node-gyp toolchain: allowlisted packages run lifecycle scripts, and bun
  # rebuilds a native dependency through node-gyp when it cannot use the shipped
  # prebuild.  POSIX passes pkgs.python3 into install-bun-packages.sh; on Windows
  # the interpreter comes from the DSC-provisioned Python 3.13 and node-gyp has to
  # be told about it explicitly — the elevated apply session can carry a PATH
  # snapshot taken before WinGet installed Python.  WHY: only probed when an
  # install is actually pending, so an already-converged machine never depends on
  # the interpreter being on PATH.
  if ($toInstall.Count -gt 0 -and -not $env:npm_config_python) {
    # check-suppress:suppression_doc: probe -- python may be absent; the if-guard reports that as an error below.
    $pythonCmd = Get-Command python.exe -ErrorAction SilentlyContinue
    if (-not $pythonCmd) {
      Write-NucleusError -CommandName 'bun-setup' "python.exe not found on PATH; node-gyp cannot rebuild native dependencies of the managed bun packages (install Python.Python.3.13 via DSC, then re-apply)"
      return
    }
    $env:npm_config_python = $pythonCmd.Source
    Write-NucleusInfo -CommandName 'bun-setup' "node-gyp Python: $env:npm_config_python"
  }

  # Install additions (fresh installs and version-mismatch reinstalls).
  # WHY: the same ~/.bunfig.toml is deployed on Windows by Sync-BunConfig.ps1 and
  # sets install.linker = "isolated", under which bun links a global package's
  # binaries only into the global node_modules/.bin and leaves
  # %USERPROFILE%\.bun\bin empty (oven-sh/bun#30450). Global installs are pinned
  # back to the hoisted linker, which is where $bunBinDir is populated.
  foreach ($pkg in $toInstall) {
    $entry = $bunVersions.$pkg
    if ($entry -is [string]) {
      # Version-pinned entry: install from npm registry.
      $version = $entry
      $installSpec = if ($version) { "${pkg}@${version}" } else { $pkg }
      Write-NucleusInfo -CommandName 'bun-setup' "installing $installSpec"
      bun install -g --linker hoisted $installSpec
      if ($LASTEXITCODE -ne 0) {
        Write-NucleusError -CommandName 'bun-setup' "'bun install -g --linker hoisted $installSpec' failed (exit $LASTEXITCODE)"
        return
      }
    } else {
      # Hash-pinned entry: install directly from VCS.
      $source = $entry.source
      $rev = $entry.rev
      $installSpec = "git+$source#$rev"
      Write-NucleusInfo -CommandName 'bun-setup' "installing $pkg from $installSpec"
      bun install -g --linker hoisted $installSpec
      if ($LASTEXITCODE -ne 0) {
        Write-NucleusError -CommandName 'bun-setup' "'bun install -g --linker hoisted $installSpec' failed (exit $LASTEXITCODE)"
        return
      }
    }
    $binName = if ($binaryNames.ContainsKey($pkg)) { $binaryNames[$pkg] } else { ($pkg -split '/')[-1] }
    if (-not (
      (Test-Path (Join-Path $bunBinDir $binName)) -or
      (Test-Path (Join-Path $bunBinDir "$binName.exe")) -or
      (Test-Path (Join-Path $bunBinDir "$binName.cmd"))
    )) {
      Write-NucleusError -CommandName 'bun-setup' "$pkg installed but binary '$binName' not found in '$bunBinDir'"
      return
    }
    Write-NucleusInfo -CommandName 'bun-setup' "$pkg installed successfully"
  }

}
