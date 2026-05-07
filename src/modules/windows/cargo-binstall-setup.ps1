# modules/windows/cargo-binstall-setup.ps1 — Declarative cargo-binstall package management.
#
# Installs and removes Rust CLI binaries via cargo-binstall for tools that are
# not available in WinGet or Scoop (the preferred channels per the repository
# install preference hierarchy: winget > scoop > cargo binstall > bun).
#
# cargo-binstall itself is installed from the Scoop main bucket by
# Invoke-ScoopSetup; this module must run after that step.

function Invoke-CargoBinstallSetup {
  <#
  .SYNOPSIS
    Idempotently converges the declarative cargo-binstall package set.

  .DESCRIPTION
    Maintains a managed set of Rust CLI binaries installed via cargo-binstall.
    On each apply it computes the diff between the desired package list and a
    per-user manifest at %USERPROFILE%\.config\nucleus\cargo-binstall-packages.json,
    installs additions via `cargo-binstall --no-confirm`, and uninstalls removals
    via `cargo uninstall`.

    Only packages absent from both WinGet and Scoop are managed here, following
    the repository preference hierarchy (nixpkgs/winget > scoop > cargo binstall).

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

  $manifestPath = Join-Path $HOME ".config\nucleus\cargo-binstall-packages.json"
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

  # Read previously-managed package list from manifest.  An absent manifest
  # (first run) is treated as an empty previous set so all desired packages
  # are treated as additions.
  $previousPackages = @()
  if (Test-Path $manifestPath) {
    try {
      $parsed = Get-Content -Path $manifestPath -Raw | ConvertFrom-Json
      if ($null -ne $parsed) {
        $previousPackages = @($parsed)
      }
    }
    catch {
      Write-Warning "Invoke-CargoBinstallSetup: manifest at '$manifestPath' could not be parsed; treating as empty"
    }
  }

  # Packages no longer desired that were previously managed by this module.
  $toRemove = @($previousPackages | Where-Object { $desiredPackages -notcontains $_ })

  # Desired packages whose binary is absent in ~/.cargo/bin.
  # Binary name matches the crate name for all managed packages.
  $toInstall = @($desiredPackages | Where-Object {
    -not (Test-Path (Join-Path $cargoBinDir "$_.exe"))
  })

  foreach ($pkg in $toRemove) {
    Write-Host "cargo-binstall-setup: uninstalling $pkg"
    cargo uninstall $pkg
    if ($LASTEXITCODE -ne 0) {
      Write-Error "cargo-binstall-setup: 'cargo uninstall $pkg' failed (exit $LASTEXITCODE)"
      return
    }
  }

  foreach ($pkg in $toInstall) {
    Write-Host "cargo-binstall-setup: installing $pkg"
    cargo-binstall --no-confirm $pkg
    if ($LASTEXITCODE -ne 0) {
      Write-Error "cargo-binstall-setup: 'cargo-binstall $pkg' failed (exit $LASTEXITCODE)"
      return
    }
    if (-not (Test-Path (Join-Path $cargoBinDir "$pkg.exe"))) {
      Write-Error "cargo-binstall-setup: $pkg installed but binary not found at '$cargoBinDir\$pkg.exe'"
      return
    }
    Write-Host "cargo-binstall-setup: $pkg installed successfully"
  }

  # Persist the current desired set as the new managed manifest so future
  # applies can compute removals when a package is dropped from the list.
  $manifestDir = Split-Path -Parent $manifestPath
  if (-not (Test-Path $manifestDir)) {
    New-Item -ItemType Directory -Path $manifestDir -Force | Out-Null
  }
  $desiredPackages | ConvertTo-Json | Set-Content -Path $manifestPath -Encoding UTF8
}
