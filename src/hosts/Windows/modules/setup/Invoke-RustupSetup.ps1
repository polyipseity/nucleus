function Invoke-RustupSetup {
  <#
  .SYNOPSIS
    Idempotently converges the declarative rustup toolchain set (install + zap).

  .DESCRIPTION
    Ensures only the declared set of Rust toolchain channels is installed.
    On each apply it queries `rustup toolchain list` for the actually installed
    toolchains, removes any whose channel prefix is not in the desired list
    (zap-style), and installs any desired channel not currently present.

    Toolchain names from rustup include the host triple suffix (e.g.
    "stable-x86_64-pc-windows-msvc").  The channel is extracted as the
    component before the first dash, so "stable-x86_64-pc-windows-msvc"
    has channel "stable".

    Requires rustup to be on PATH (installed from WinGet by system/packages.dsc.yml).

  .EXAMPLE
    Invoke-RustupSetup

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
  $rustupVersions = if ($lockfile -and $lockfile.rustup) { $lockfile.rustup } else { @{} }

  # Declarative desired-state list of toolchain channels.  Add a channel name
  # here to install it; remove it to trigger removal on the next apply.  Use
  # the short channel name without the host triple (rustup appends the host
  # triple automatically).
  $desiredChannels = @(
    # Stable Rust toolchain; required by cargo-binstall for compilation fallback
    # and used as the default toolchain for all Rust development.
    'stable'
  )

  # Guard: rustup must be accessible after WinGet DSC has installed Rustlang.Rustup.
  # undoc-supp: probe — rustup may not be installed; if-guard checks absence below.
  if (-not (Get-Command rustup -ErrorAction SilentlyContinue)) {
    Write-Error "Invoke-RustupSetup: rustup not found on PATH; ensure Rustlang.Rustup was installed by WinGet DSC before calling this function"
    return
  }

  # Prepend ~/.cargo/bin so cargo binaries (including cargo uninstall, used
  # by Invoke-CargoBinstallSetup) are accessible after rustup sets up a
  # toolchain in this session.
  # Canonical source: ManagedPaths.ps1 -> managed-paths.nix (pathComponents).
  $cargoBinDir = Get-NucleusManagedBinDir "cargo"
  if ($env:PATH -notlike "*$cargoBinDir*") {
    $env:PATH = "$env:PATH;$cargoBinDir"
  }

  # Get actually installed toolchains from rustup.  `rustup toolchain list`
  # emits lines like "stable-x86_64-pc-windows-msvc (default)" or
  # "nightly-x86_64-pc-windows-msvc".  The first whitespace-delimited token
  # is the full toolchain name.
  $rawToolchains = @(rustup toolchain list 2>&1 | Where-Object { $_ -match '\S' })
  $installedToolchains = @($rawToolchains | ForEach-Object { ($_ -split '\s+')[0] })

  # Extract the channel from each installed toolchain name by taking everything
  # before the first dash.  Examples:
  #   stable-x86_64-pc-windows-msvc  → stable
  #   nightly-x86_64-pc-windows-msvc → nightly
  #   1.75.0-x86_64-pc-windows-msvc  → 1.75.0 (pinned version, not a channel)
  $installedChannels = @($installedToolchains | ForEach-Object { ($_ -split '-')[0] })

  # Toolchains to remove: installed ones whose channel is not in the desired
  # list, OR whose installed version does not match the lockfile pin.
  $toRemove = @($installedToolchains | Where-Object {
    $channel = ($_ -split '-')[0]
    if ($desiredChannels -notcontains $channel) { return $true }
    $expectedDate = $rustupVersions.$channel
    if (-not $expectedDate) { return $false }
    -not ($_ -match "$channel-$expectedDate-")
  })

  # Channels to install: desired ones not currently present in any installed toolchain.
  $toInstall = @($desiredChannels | Where-Object {
    $channel = $_
    $installedChannels -notcontains $channel
  })

  # Remove toolchains whose channel is not in the desired list.
  foreach ($toolchain in $toRemove) {
    Write-Output "rustup: removing toolchain '$toolchain'"
    rustup toolchain remove $toolchain
    if ($LASTEXITCODE -ne 0) {
      Write-Error "rustup: 'rustup toolchain remove $toolchain' failed (exit $LASTEXITCODE)"
      return
    }
    Write-Output "rustup: '$toolchain' removed"
  }

  # Install desired channels not currently present with version pinning from lockfile.
  foreach ($channel in $toInstall) {
    $rustupDate = $rustupVersions.$channel
    $channelSpec = if ($rustupDate) { "${channel}-${rustupDate}" } else { $channel }
    Write-Output "rustup: installing toolchain '$channelSpec'"
    rustup toolchain install $channelSpec
    if ($LASTEXITCODE -ne 0) {
      Write-Error "rustup: 'rustup toolchain install $channelSpec' failed (exit $LASTEXITCODE)"
      return
    }
    Write-Output "rustup: '$channelSpec' installed"
  }

  if ($toInstall.Count -eq 0 -and $toRemove.Count -eq 0) {
    Write-Output "rustup: all managed toolchains already converged — skipping"
  }

  # Set the global default toolchain to none so every project must declare its
  # toolchain explicitly via rust-toolchain.toml or a +channel override.
  # undoc-supp: a global default channel silently masks missing per-project toolchain
  # files and makes the effective compiler version opaque.
  # `rustup default none` is idempotent.
  Write-Output "rustup: setting global default toolchain to none"
  rustup default none
  if ($LASTEXITCODE -ne 0) {
    Write-Error "rustup: 'rustup default none' failed (exit $LASTEXITCODE)"
    return
  }
  Write-Output "rustup: global default toolchain set to none"

  Write-CargoConfig
}

function Write-CargoConfig {
  <#
  .SYNOPSIS
    Writes per-platform Cargo linker configuration to ~\.cargo\config.toml.

  .DESCRIPTION
    Creates ~\.cargo\config.toml with the same cfg(target_os)-based linker
    selection as the POSIX shell module.  On Windows rust-lld (bundled with
    the Rust toolchain) is used, matching the Windows section of the config.

    The file is written unconditionally: Cargo ignores non-matching sections
    and home-manager already manages the same file on POSIX hosts, so this is
    the Windows-only equivalent.

  .EXAMPLE
    Write-CargoConfig

  .NOTES
    Environment variables: (none)
    Exit codes: 0 on success; non-zero on failure.
  #>
  [CmdletBinding()]
  param()

  $configDir = "$env:USERPROFILE\.cargo"
  $configPath = "$configDir\config.toml"

  # Ensure ~\.cargo exists.
  if (-not (Test-Path $configDir)) {
    $null = New-Item -ItemType Directory -Path $configDir -Force
  }

  $configContent = @'
# ── Linux: mold via Clang ──────────────────────────────────────────────────
# mold is the fastest linker available. clang is used as the driver because
# it correctly passes -fuse-ld=mold to the linker invocation.
[target.'cfg(target_os = "linux")']
linker = "clang"
rustflags = ["-C", "link-arg=-fuse-ld=mold"]

# ── macOS: native Apple ld64 via system C compiler ────────────────────────
# Apple's ld64 is well-optimised for mach-o binaries.  cc resolves to the
# Nix-managed clang, which invokes /usr/bin/ld (Apple ld64) for the final
# link step.
[target.'cfg(target_os = "macos")']
linker = "cc"

# ── Windows: LLVM linker bundled with Rust toolchain ──────────────────────
# lld-link is a drop-in replacement for MSVC link.exe and requires no
# additional installation.
[target.'cfg(target_os = "windows")']
linker = "rust-lld"
'@

  Write-Output "cargo-config: writing linker config to $configPath"
  Set-Content -Path $configPath -Value $configContent -NoNewline
  Write-Output "cargo-config: $configPath written"
}
