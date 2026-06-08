function Invoke-CargoBinstallSetup {
  <#
  .SYNOPSIS
    Idempotently converges the declarative cargo-binstall package set.

  .DESCRIPTION
    Maintains a managed set of Rust CLI binaries installed via cargo-binstall.
    On each apply it queries `cargo install --list` for the actually installed
    set and removes anything not in the desired list (zap-style), then installs
    any desired packages that are missing via `cargo-binstall --no-confirm` at
    versions pinned in the repository lockfile.

    Only packages absent from both WinGet and Scoop are managed here, following
    the repository preference hierarchy (nixpkgs/winget > scoop > cargo binstall > bun > uv).

    Currently managed:
      - cargo-cache    — reclaim disk space from ~/.cargo registry, git, and
                         advisory-db clones; fills the Windows cargo-cache gap
                         (no WinGet package ID; not in Scoop)
      - pay-respects   — command correction tool (actively maintained fork of
                         thefuck); fills the Windows pay-respects gap
                         (no WinGet package ID; not in Scoop)

    Requires cargo-binstall to be on PATH (installed from Scoop main bucket by
    Invoke-ScoopSetup).  Prepends %USERPROFILE%\.cargo\bin to PATH internally
    so `cargo uninstall` (removal path) works even when the calling session
    was started before rustup initialised PATH.

  .EXAMPLE
    Invoke-CargoBinstallSetup

  .NOTES
    Environment variables: (none)
    Exit codes: 0 on success; non-zero on failure.
  #>
  [CmdletBinding()]
  param()

  # Derive repo root from script location (src/hosts/Windows/modules/setup/ -> repo root is 5 levels up).
  $repoRoot = Resolve-Path "$PSScriptRoot\..\..\..\..\.."
  $lockfilePath = Join-Path $repoRoot "lockfiles\lockfile.json"

  # Read version-pinning data from the consolidated lockfile.
  $lockfile = @{}
  if (Test-Path $lockfilePath) {
    $lockfile = Get-Content $lockfilePath -Raw | ConvertFrom-Json
  }
  $cargoBinstallVersions = if ($lockfile -and $lockfile.'cargo-binstall') { $lockfile.'cargo-binstall' } else { @{} }

  # Structured desired-state list.  Each entry has a CrateName (published on
  # crates.io) and a BinaryName (the executable placed in ~/.cargo/bin).
  # The two may differ when a crate installs a binary under a different name
  # (for example nickel-lang-lsp installs nls.exe, not nickel-lang-lsp.exe).
  # Add an entry here to install it; remove it to trigger uninstall on the
  # next apply.  Only add packages absent from both WinGet and Scoop.
  $desiredPackages = @(
    [pscustomobject]@{ CrateName = 'cargo-cache'; BinaryName = 'cargo-cache' }
    # nickel-lang-lsp provides the nls (Nickel Language Server) binary required
    # by the tweag.vscode-nickel VS Code extension for Nickel file editing.
    # nls is not available in WinGet or Scoop; cargo-binstall downloads nls.exe
    # from the nickel-lang GitHub release assets.
    # Cross-platform parity: pkgs.nls in baseSharedPackages on POSIX.
    [pscustomobject]@{ CrateName = 'nickel-lang-lsp'; BinaryName = 'nls' }
    # nix-index is managed on POSIX hosts (pkgs.nix-index in core.nix plus
    # a LaunchAgent/systemd timer for periodic DB builds) but has no Windows
    # equivalent and is not needed here.  pay-respects on Windows never
    # attempts nix package lookup because `nix` is never in PATH; the
    # nix-locate code path is simply never reached.
    [pscustomobject]@{ CrateName = 'pay-respects'; BinaryName = 'pay-respects' }
  )

  # cargo-binstall and `cargo uninstall` both operate on this directory.
  $cargoBinDir = Join-Path $HOME ".cargo\bin"

  # Prepend ~/.cargo/bin so `cargo uninstall` (removal path) finds the cargo
  # binary even when the calling session predates rustup's PATH initialisation.
  if ($env:PATH -notlike "*$cargoBinDir*") {
    $env:PATH = "$cargoBinDir;$env:PATH"
  }

  # Guard: cargo-binstall must be accessible after Invoke-ScoopSetup has run.
  if (-not (Get-Command cargo-binstall -ErrorAction SilentlyContinue)) {
    # -ErrorAction SilentlyContinue is intentional: absence of cargo-binstall
    # is an expected probe condition; the if-guard checks the result immediately.
    Write-Error "Invoke-CargoBinstallSetup: cargo-binstall not found on PATH; ensure Invoke-ScoopSetup has run and installed cargo-binstall from the Scoop main bucket"
    return
  }

  # Get actually installed crates from `cargo install --list` (zap-style:
  # remove any installed crate absent from the desired list, regardless of
  # prior managed state).  `cargo install --list` emits lines of the form
  # "name vX.Y.Z:" for each installed crate.
  $cargoListOutput = @(cargo install --list 2>&1)
  $installedVersions = @{}
  $installedCrates = @(
    $cargoListOutput |
      Where-Object { $_ -match '^([a-zA-Z0-9_-]+) v(\S+)' } |
      ForEach-Object {
        $installedVersions[$matches[1]] = $matches[2] -replace ':', ''
        $matches[1]
      }
  )

  # Crates installed but not desired: zap-style removal.
  # Mirrors homebrew cleanup = "zap": removes anything installed but absent
  # from the declared desired set, regardless of how it was installed.
  $desiredCrateNames = @($desiredPackages | ForEach-Object { $_.CrateName })
  $toRemove = @($installedCrates | Where-Object { $desiredCrateNames -notcontains $_ })

  # Desired crates not yet installed OR installed at a version different from
  # the lockfile pin (version-aware reconciliation).
  $toInstall = @($desiredPackages | Where-Object {
    $crateName = $_.CrateName
    $isInstalled = $installedCrates -contains $crateName
    if (-not $isInstalled) { return $true }
    $entry = $cargoBinstallVersions.$crateName
    if ($entry -is [string]) {
      # Version-pinned entry: reinstall if version mismatch.
      if (-not $entry) { return $false }
      $installedVersion = $installedVersions[$crateName]
      return $installedVersion -ne $entry
    }
    # Hash-pinned entry (PSObject with .source/.rev): already installed, skip.
    return $false
  })

  foreach ($pkg in $toRemove) {
    Write-Output "cargo-binstall-setup: uninstalling $pkg"
    cargo uninstall $pkg
    if ($LASTEXITCODE -ne 0) {
      Write-Error "cargo-binstall-setup: 'cargo uninstall $pkg' failed (exit $LASTEXITCODE)"
      return
    }
    Write-Output "cargo-binstall-setup: $pkg uninstalled"
  }

  # Install additions (fresh installs and version-mismatch reinstalls).
  foreach ($pkg in $toInstall) {
    $crateName = $pkg.CrateName
    $entry = $cargoBinstallVersions.$crateName
    if ($entry -is [string]) {
      # Version-pinned entry: install via cargo-binstall.
      $version = $entry
      $installSpec = if ($version) { "$crateName@$version" } else { $crateName }
      Write-Output "cargo-binstall-setup: installing $installSpec"
      cargo-binstall --no-confirm $installSpec
      if ($LASTEXITCODE -ne 0) {
        Write-Error "cargo-binstall-setup: 'cargo-binstall $installSpec' failed (exit $LASTEXITCODE)"
        return
      }
    } else {
      # Hash-pinned entry: install directly from VCS via cargo install.
      $source = $entry.source
      $rev = $entry.rev
      Write-Output "cargo-binstall-setup: installing $crateName from $source @ $rev"
      cargo install --git $source --rev $rev $crateName
      if ($LASTEXITCODE -ne 0) {
        Write-Error "cargo-binstall-setup: 'cargo install --git $source --rev $rev $crateName' failed (exit $LASTEXITCODE)"
        return
      }
    }
    if (-not (Test-Path (Join-Path $cargoBinDir "$($pkg.BinaryName).exe"))) {
      Write-Error "cargo-binstall-setup: $crateName installed but $($pkg.BinaryName).exe not found at '$cargoBinDir\$($pkg.BinaryName).exe'"
      return
    }
    Write-Output "cargo-binstall-setup: $crateName installed successfully"
  }

  if ($toRemove.Count -eq 0 -and $toInstall.Count -eq 0) {
    Write-Output "cargo-binstall-setup: all managed packages already converged — skipping"
  }
}
