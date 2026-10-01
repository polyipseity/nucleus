function Invoke-RustupSetup {
  <#
  .SYNOPSIS
    Idempotently converges the declarative rustup toolchain set (install + zap).

  .DESCRIPTION
    Install only the declared set of Rust toolchain channels.

    Requires rustup to be on PATH (installed from WinGet by system/packages.dsc.yml).

  .EXAMPLE
    Invoke-RustupSetup
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $false)]
    [string]$User,

    [Parameter(Mandatory = $false)]
    [string]$RepoRoot
  )

  if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    $RepoRoot = Resolve-Path "$PSScriptRoot\..\..\..\..\.."
  }
  if ([string]::IsNullOrWhiteSpace($User)) {
    $User = $env:USERNAME
  }

  $lockfilePath = Join-Path $RepoRoot "src\lockfiles\lockfile.json"

  $lockfile = @{}
  if (Test-Path $lockfilePath) {
    $lockfile = Get-Content $lockfilePath -Raw | ConvertFrom-Json
  }
  $rustupVersions = if ($lockfile -and $lockfile.rustup) { $lockfile.rustup } else { @{} }

  # Add a channel name here to install it, remove it to trigger removal.
  # Use the short name; rustup appends the host triple.
  $desiredChannels = @(
    # Stable is the cargo-binstall compilation fallback and the Rust default.
    'stable'
  )

  # WinGet DSC installs Rustlang.Rustup before this runs.
  # check-suppress:suppression_doc: probe -- rustup may not be installed; if-guard checks absence below.
  if (-not (Get-Command rustup -ErrorAction SilentlyContinue)) {
    Write-NucleusError -CommandName 'Invoke-RustupSetup' "rustup not found on PATH; ensure Rustlang.Rustup was installed by WinGet DSC before calling this function"
    return
  }

  # Prepend ~/.cargo/bin so cargo binaries (including cargo uninstall, used
  # by Invoke-CargoBinstallSetup) resolve in this session.
  $cargoBinDir = Get-NucleusManagedBinDir "cargo"
  if ($env:PATH -notlike "*$cargoBinDir*") {
    $env:PATH = "$env:PATH;$cargoBinDir"
  }

  # The active toolchain carries a "(default)" suffix; the first token is the name.
  $rawToolchains = @(rustup toolchain list 2>&1 | Where-Object { $_ -match '\S' })
  $installedToolchains = @($rawToolchains | ForEach-Object { ($_ -split '\s+')[0] })

  # The channel is the part before the first dash; a pinned version is 1.75.0.
  $installedChannels = @($installedToolchains | ForEach-Object { ($_ -split '-')[0] })

  # Remove an installed toolchain when its channel is not desired, or when a
  # nightly pin's archive date does not match. stable/beta are rolling, pinned
  # by version only, so membership is the whole test.
  $toRemove = @($installedToolchains | Where-Object {
    $channel = ($_ -split '-')[0]
    if ($desiredChannels -notcontains $channel) { return $true }
    $pin = $rustupVersions.$channel
    # Only nightly pins carry a -YYYY-MM-DD archive suffix that can be matched
    # against an installed toolchain name; version pins for stable/beta are
    # tracked only and never used to remove by version.
    if ($pin -and $pin -match '^nightly-\d{4}-\d{2}-\d{2}$') {
      return -not ($_ -match [regex]::Escape($pin))
    }
    return $false
  })

  $toInstall = @($desiredChannels | Where-Object {
    $channel = $_
    $installedChannels -notcontains $channel
  })

  foreach ($toolchain in $toRemove) {
    Write-NucleusInfo -CommandName 'rustup' "removing toolchain '$toolchain'"
    rustup toolchain remove $toolchain
    if ($LASTEXITCODE -ne 0) {
      Write-NucleusError -CommandName 'rustup' "'rustup toolchain remove $toolchain' failed (exit $LASTEXITCODE)"
      return
    }
    Write-NucleusInfo -CommandName 'rustup' "'$toolchain' removed"
  }

  foreach ($channel in $toInstall) {
    # A nightly pin carries a -YYYY-MM-DD archive suffix and is used verbatim;
    # stable/beta are installed by name alone.
    $pin = $rustupVersions.$channel
    $channelSpec = if ($pin -and $pin -match '^nightly(-\d{4}-\d{2}-\d{2})?$') { $pin } else { $channel }
    Write-NucleusInfo -CommandName 'rustup' "installing toolchain '$channelSpec'"
    rustup toolchain install $channelSpec
    if ($LASTEXITCODE -ne 0) {
      Write-NucleusError -CommandName 'rustup' "'rustup toolchain install $channelSpec' failed (exit $LASTEXITCODE)"
      return
    }
    Write-NucleusInfo -CommandName 'rustup' "'$channelSpec' installed"
  }

  if ($toInstall.Count -eq 0 -and $toRemove.Count -eq 0) {
    Write-NucleusInfo -CommandName 'rustup' "all managed toolchains already converged — skipping"
  }

  # Set the global default toolchain to none so every project must declare its
  # toolchain explicitly via rust-toolchain.toml or a +channel override.
  # check-suppress:suppression_doc: a global default channel silently masks missing per-project toolchain
  # files and makes the effective compiler version opaque.
  Write-NucleusInfo -CommandName 'rustup' "setting global default toolchain to none"
  rustup default none
  if ($LASTEXITCODE -ne 0) {
    Write-NucleusError -CommandName 'rustup' "'rustup default none' failed (exit $LASTEXITCODE)"
    return
  }
  Write-NucleusInfo -CommandName 'rustup' "global default toolchain set to none"

  # check-suppress:config-method: method 1 (writable symlink) -- cargo config symlinked to repo file.
  # Mirrors the POSIX shell.nix deployment of cargo/config.toml.
  $cargoConfigDir = "$env:USERPROFILE\.cargo"
  $cargoConfigPath = "$cargoConfigDir\config.toml"
  if (-not (Test-Path -Path $cargoConfigDir)) {
    $null = New-Item -ItemType Directory -Path $cargoConfigDir -Force  # check-suppress:suppression_doc: New-Item returns DirectoryInfo, discarded
  }
  $result = Deploy-UserWritableSymlink -Name 'cargo' -User $User -ConfigName 'cargo' -RelativePath 'config.toml' -RepoRoot $RepoRoot -TargetPath $cargoConfigPath
  Write-NucleusInfo -CommandName 'cargo' ($result.Message -replace '^cargo: ', '')
}
