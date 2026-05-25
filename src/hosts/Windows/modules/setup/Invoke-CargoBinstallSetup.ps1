# modules/Windows/cargo-binstall-setup.ps1 — Declarative cargo-binstall package management.
#
# Installs and removes Rust CLI binaries via cargo-binstall for tools that are
# not available in WinGet or Scoop (the preferred channels per the repository
# install preference hierarchy: winget > scoop > cargo binstall > bun > uv).
#
# cargo-binstall itself is installed from the Scoop main bucket by
# Invoke-ScoopSetup; this module must run after that step.

function Invoke-CargoBinstallSetup {
  <#
  .SYNOPSIS
    Idempotently converges the declarative cargo-binstall package set.

  .DESCRIPTION
    Maintains a managed set of Rust CLI binaries installed via cargo-binstall.
    On each apply it queries `cargo install --list` for the actually installed
    set and removes anything not in the desired list (zap-style), then installs
    any desired packages that are missing via `cargo-binstall --no-confirm`.

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
  #>
  [CmdletBinding()]
  param()

  # Declarative desired-state list.  Add a crate name here to install it;
  # remove it to trigger uninstall on the next apply.  Use the exact crate
  # name as published on crates.io.  Only add packages absent from both
  # WinGet and Scoop.
  $desiredPackages = @(
    'cargo-cache'
    # nix-index is managed on POSIX hosts (pkgs.nix-index in core.nix plus
    # a LaunchAgent/systemd timer for periodic DB builds) but has no Windows
    # equivalent and is not needed here.  pay-respects on Windows never
    # attempts nix package lookup because `nix` is never in PATH; the
    # nix-locate code path is simply never reached.
    'pay-respects'
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
  $installedCrates = @(
    $cargoListOutput |
      Where-Object { $_ -match '^[a-zA-Z0-9_-]+ v' } |
      ForEach-Object { ($_ -split '\s+')[0] }
  )

  # Crates installed but not desired: zap-style removal.
  # Mirrors homebrew cleanup = "zap": removes anything installed but absent
  # from the declared desired set, regardless of how it was installed.
  $toRemove = @($installedCrates | Where-Object { $desiredPackages -notcontains $_ })

  # Desired crates not yet installed (absent from cargo install --list or
  # binary missing from ~/.cargo/bin).
  $toInstall = @($desiredPackages | Where-Object {
    $pkg = $_
    $installedCrates -notcontains $pkg
  })

  foreach ($pkg in $toRemove) {
    Write-Output "cargo-binstall-setup: uninstalling $pkg"
    cargo uninstall $pkg
    if ($LASTEXITCODE -ne 0) {
      Write-Error "cargo-binstall-setup: 'cargo uninstall $pkg' failed (exit $LASTEXITCODE)"
      return
    }
  }

  foreach ($pkg in $toInstall) {
    Write-Output "cargo-binstall-setup: installing $pkg"
    cargo-binstall --no-confirm $pkg
    if ($LASTEXITCODE -ne 0) {
      Write-Error "cargo-binstall-setup: 'cargo-binstall $pkg' failed (exit $LASTEXITCODE)"
      return
    }
    if (-not (Test-Path (Join-Path $cargoBinDir "$pkg.exe"))) {
      Write-Error "cargo-binstall-setup: $pkg installed but binary not found at '$cargoBinDir\$pkg.exe'"
      return
    }
    Write-Output "cargo-binstall-setup: $pkg installed successfully"
  }

  if ($toRemove.Count -eq 0 -and $toInstall.Count -eq 0) {
    Write-Output "cargo-binstall-setup: all managed packages already converged — skipping"
  }
}
