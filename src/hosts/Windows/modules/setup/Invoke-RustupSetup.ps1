# modules/Windows/rustup-setup.ps1 — Declarative rustup toolchain management.
#
# Ensures only the declared set of Rust toolchains is installed via rustup.
# Uses zap-style pruning: any toolchain whose channel is not in the desired
# list is removed, mirroring homebrew's cleanup = "zap" behaviour.
#
# rustup itself is installed from WinGet (Rustlang.Rustup in system.dsc.yml).
# This module must run after the WinGet DSC step.

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

    Requires rustup to be on PATH (installed from WinGet by system.dsc.yml).

  .EXAMPLE
    Invoke-RustupSetup
  #>
  [CmdletBinding()]
  param()

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
  if (-not (Get-Command rustup -ErrorAction SilentlyContinue)) {
    # -ErrorAction SilentlyContinue is intentional: absence of rustup is an
    # expected probe condition; the if-guard checks the result immediately.
    Write-Error "Invoke-RustupSetup: rustup not found on PATH; ensure Rustlang.Rustup was installed by WinGet DSC before calling this function"
    return
  }

  # Prepend ~/.cargo/bin so cargo binaries (including cargo uninstall, used
  # by Invoke-CargoBinstallSetup) are accessible after rustup sets up a
  # toolchain in this session.
  $cargoBinDir = Join-Path $HOME ".cargo\bin"
  if ($env:PATH -notlike "*$cargoBinDir*") {
    $env:PATH = "$cargoBinDir;$env:PATH"
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

  # Toolchains to remove: installed ones whose channel is not in the desired list.
  $toRemove = @($installedToolchains | Where-Object {
    $channel = ($_ -split '-')[0]
    $desiredChannels -notcontains $channel
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

  # Install desired channels not currently present.
  foreach ($channel in $toInstall) {
    Write-Output "rustup: installing toolchain '$channel'"
    rustup toolchain install $channel
    if ($LASTEXITCODE -ne 0) {
      Write-Error "rustup: 'rustup toolchain install $channel' failed (exit $LASTEXITCODE)"
      return
    }
    Write-Output "rustup: '$channel' installed"
  }

  if ($toInstall.Count -eq 0 -and $toRemove.Count -eq 0) {
    Write-Output "rustup: all managed toolchains already converged — skipping"
  }

  # Set the global default toolchain to none so every project must declare its
  # toolchain explicitly via rust-toolchain.toml or a +channel override.
  # WHY: a global default channel silently masks missing per-project toolchain
  # files and makes the effective compiler version opaque.
  # `rustup default none` is idempotent.
  Write-Output "rustup: setting global default toolchain to none"
  rustup default none
  if ($LASTEXITCODE -ne 0) {
    Write-Error "rustup: 'rustup default none' failed (exit $LASTEXITCODE)"
    return
  }
  Write-Output "rustup: global default toolchain set to none"
}
