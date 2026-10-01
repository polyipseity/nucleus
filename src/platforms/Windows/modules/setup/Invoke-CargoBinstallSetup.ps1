function Invoke-CargoBinstallSetup {
  <#
  .SYNOPSIS
    Idempotently converges the declarative cargo-binstall package set.

  .DESCRIPTION
    Maintains a managed set of Rust CLI binaries installed via cargo-binstall.

    Only packages absent from both WinGet and Scoop are managed here, following
    the repository preference hierarchy (nixpkgs/winget > scoop > cargo binstall > cargo > bun > uv).

    Requires cargo-binstall to be on PATH (installed from Scoop main bucket by
    Invoke-ScoopSetup). Prepends %USERPROFILE%\.cargo\bin to PATH internally
    so `cargo uninstall` (removal path) works even when the calling session
    was started before rustup initialised PATH.

  .EXAMPLE
    Invoke-CargoBinstallSetup
  #>
  [CmdletBinding()]
  param()

  $repoRoot = Resolve-Path "$PSScriptRoot\..\..\..\..\.."
  $lockfilePath = Join-Path $repoRoot "src\lockfiles\lockfile.json"

  . (Join-Path -Path $repoRoot -ChildPath "src\platforms\Windows\modules\Get-NucleusHostPlatform.ps1")

  $lockfile = @{}
  if (Test-Path $lockfilePath) {
    $lockfile = Get-Content $lockfilePath -Raw | ConvertFrom-Json
  }
  $cargoBinstallVersions = if ($lockfile -and $lockfile.'cargo-binstall') { $lockfile.'cargo-binstall' } else { @{} }

  # CrateName and BinaryName differ when a crate installs its binary under
  # another name (nickel-lang-lsp installs nls.exe). No "binary" field means
  # the binary is named after the crate.
  $desiredPath = Join-Path $repoRoot "src\modules\packages\desired.json"
  if (-not (Test-Path -LiteralPath $desiredPath)) {
    Write-NucleusError -CommandName 'Invoke-CargoBinstallSetup' "desired package registry not found at '$desiredPath'"
    return
  }
  $hostKey = Get-NucleusHostKey
  $hostDesired = (Get-Content -LiteralPath $desiredPath -Raw | ConvertFrom-Json).'cargo-binstall'.$hostKey
  if ($null -eq $hostDesired) {
    Write-NucleusError -CommandName 'Invoke-CargoBinstallSetup' "desired package registry has no cargo-binstall list for host '$hostKey'"
    return
  }
  $desiredPackages = @($hostDesired | ForEach-Object {
      $binaryName = if ($_.binary) { $_.binary } else { $_.name }
      [pscustomobject]@{
        CrateName  = $_.name
        BinaryName = $binaryName
      }
    })

  $cargoBinDir = Get-NucleusManagedBinDir "cargo"

  # `cargo uninstall` (removal path) needs cargo on PATH even when the calling
  # session predates rustup's PATH initialisation.
  if ($env:PATH -notlike "*$cargoBinDir*") {
    $env:PATH = "$env:PATH;$cargoBinDir"
  }

  # Guard: cargo-binstall must be accessible after Invoke-ScoopSetup has run.
  # check-suppress:suppression_doc: probe -- cargo-binstall may not be installed; if-guard checks absence below.
  if (-not (Get-Command cargo-binstall -ErrorAction SilentlyContinue)) {
    Write-NucleusError -CommandName 'Invoke-CargoBinstallSetup' "cargo-binstall not found on PATH; ensure Invoke-ScoopSetup has run and installed cargo-binstall from the Scoop main bucket"
    return
  }

  # sccache as RUSTC_WRAPPER so the cargo install fallback finds it even when
  # the session PATH is restricted.
  $savedRustcWrapper = $env:RUSTC_WRAPPER
  # check-suppress:suppression_doc: probe -- sccache may not be installed; EnvVarOverride block handles absence.
  $_sccacheCmd = Get-Command sccache -ErrorAction SilentlyContinue
  if ($_sccacheCmd) {
    $env:RUSTC_WRAPPER = $_sccacheCmd.Source
  }

  # `cargo install --list` emits "name vX.Y.Z:" per installed crate.
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

  # Removing an installed crate absent from the declared set, however it got installed.
  $desiredCrateNames = @($desiredPackages | ForEach-Object { $_.CrateName })
  $toRemove = @($installedCrates | Where-Object { $desiredCrateNames -notcontains $_ })

  # Missing, or installed at a version other than the pin.
  $toInstall = @($desiredPackages | Where-Object {
    $crateName = $_.CrateName
    $isInstalled = $installedCrates -contains $crateName
    if (-not $isInstalled) { return $true }
    $entry = $cargoBinstallVersions.$crateName
    if ($entry -is [string]) {
      if (-not $entry) { return $false }
      $installedVersion = $installedVersions[$crateName]
      return $installedVersion -ne $entry
    }
    # Hash-pinned entry (PSObject with .source/.rev): already installed, skip.
    return $false
  })

  foreach ($pkg in $toRemove) {
    Write-NucleusInfo -CommandName 'cargo-binstall-setup' "uninstalling $pkg"
    cargo uninstall $pkg
    if ($LASTEXITCODE -ne 0) {
      Write-NucleusError -CommandName 'cargo-binstall-setup' "'cargo uninstall $pkg' failed (exit $LASTEXITCODE)"
      return
    }
    Write-NucleusInfo -CommandName 'cargo-binstall-setup' "$pkg uninstalled"
  }

  foreach ($pkg in $toInstall) {
    $crateName = $pkg.CrateName
    $entry = $cargoBinstallVersions.$crateName
    if ($entry -is [string]) {
      $version = $entry
      $installSpec = if ($version) { "$crateName@$version" } else { $crateName }
      Write-NucleusInfo -CommandName 'cargo-binstall-setup' "installing $installSpec"
      cargo-binstall --no-confirm $installSpec
      if ($LASTEXITCODE -ne 0) {
        Write-NucleusError -CommandName 'cargo-binstall-setup' "'cargo-binstall $installSpec' failed (exit $LASTEXITCODE)"
        return
      }
    } else {
      $source = $entry.source
      $rev = $entry.rev
      Write-NucleusInfo -CommandName 'cargo-binstall-setup' "installing $crateName from $source @ $rev"
      cargo install --git $source --rev $rev $crateName
      if ($LASTEXITCODE -ne 0) {
        Write-NucleusError -CommandName 'cargo-binstall-setup' "'cargo install --git $source --rev $rev $crateName' failed (exit $LASTEXITCODE)"
        return
      }
    }
    if (-not (Test-Path (Join-Path $cargoBinDir "$($pkg.BinaryName).exe"))) {
      Write-NucleusError -CommandName 'cargo-binstall-setup' "$crateName installed but $($pkg.BinaryName).exe not found at '$cargoBinDir\$($pkg.BinaryName).exe'"
      return
    }
    Write-NucleusInfo -CommandName 'cargo-binstall-setup' "$crateName installed successfully"
  }

  if ($toRemove.Count -eq 0 -and $toInstall.Count -eq 0) {
    Write-NucleusInfo -CommandName 'cargo-binstall-setup' "all managed packages already converged — skipping"
  }

  $env:RUSTC_WRAPPER = $savedRustcWrapper
}
