# modules/windows/bun-setup.ps1 — Declarative bun global package management.
#
# Installs and removes JS CLI tools via `bun install -g` for packages that are
# not available in WinGet, Scoop, or cargo-binstall.  Bun occupies the last
# tier of the repository install preference hierarchy:
#   nixpkgs/winget > scoop > cargo binstall > bun
#
# Bun itself is installed from WinGet (Oven-sh.Bun in system.dsc.yml).
# This module must run after the WinGet DSC step.

function Invoke-BunSetup {
  <#
  .SYNOPSIS
    Idempotently converges the declarative bun global package set.

  .DESCRIPTION
    Maintains a managed set of JS CLI tools installed via `bun install -g`.
    On each apply it computes the diff between the desired package list and a
    per-user manifest at %USERPROFILE%\.config\nucleus\bun-packages.json,
    installs additions via `bun install -g`, and removes deletions via
    `bun remove -g`.

    Only packages absent from WinGet, Scoop, and cargo-binstall are managed
    here, following the repository preference hierarchy
    (nixpkgs/winget > scoop > cargo binstall > bun).

    Currently managed:
      - @google/gemini-cli         — Gemini terminal agent CLI.  Dedicated
                                     WinGet package ID is not currently
                                     confirmed in winget-pkgs manifests, so
                                     bun is the reliable install tier on
                                     Windows for now
      - @mariozechner/pi-coding-agent — coding agent CLI (pi); available in
                                         nixpkgs on POSIX (pkgs.pi-coding-agent)
                                         but has no WinGet, Scoop, or
                                         cargo-binstall package on Windows
      - clawhub                        — fetched skill install vehicle; absent
                                         from WinGet, Scoop, and cargo-binstall;
                                         bun is the only viable install tier

    Requires bun to be on PATH (installed from WinGet by system.dsc.yml).
    Prepends %USERPROFILE%\.bun\bin to PATH internally so bun-installed
    binaries are accessible in subsequent steps of the same apply session.

  .EXAMPLE
    Invoke-BunSetup
  #>
  [CmdletBinding()]
  param()

  # Declarative desired-state list.  Add a package name here to install it;
  # remove it to trigger uninstall on the next apply.  Use the exact npm
  # package name (including scope if applicable).  Only add packages absent
  # from WinGet, Scoop, and cargo-binstall.
  $desiredPackages = @(
    # Gemini terminal agent CLI; no confirmed dedicated WinGet package ID in
    # winget-pkgs manifests at time of writing, so bun is used as fallback.
    '@google/gemini-cli',
    # coding agent CLI; available via pkgs.pi-coding-agent on POSIX but absent
    # from WinGet, Scoop, and cargo-binstall on Windows
    '@mariozechner/pi-coding-agent',
    # fetched skill install vehicle; absent from WinGet, Scoop, and
    # cargo-binstall; bun is the only viable install tier on Windows
    'clawhub'
  )

  # bun install -g places binaries in ~\.bun\bin by default (BUN_INSTALL_BIN).
  $bunBinDir = Join-Path $HOME ".bun\bin"
  $manifestPath = Join-Path $HOME ".config\nucleus\bun-packages.json"

  # Guard: bun must be accessible after WinGet DSC has installed Oven-sh.Bun.
  if (-not (Get-Command bun -ErrorAction SilentlyContinue)) {
    # -ErrorAction SilentlyContinue is intentional: absence of bun is an
    # expected probe condition; the if-guard checks the result immediately.
    Write-Error "Invoke-BunSetup: bun not found on PATH; ensure Oven-sh.Bun was installed by WinGet DSC before calling this function"
    return
  }

  # Prepend ~/.bun/bin so binaries installed during this apply run are
  # accessible in subsequent steps without opening a new terminal session.
  if ($env:PATH -notlike "*$bunBinDir*") {
    $env:PATH = "$bunBinDir;$env:PATH"
  }

  # Read the previously-managed package list from the manifest.  An absent
  # manifest (first run) is treated as an empty previous set so all desired
  # packages are treated as additions.
  $previousPackages = @()
  if (Test-Path $manifestPath) {
    try {
      $parsed = Get-Content -Path $manifestPath -Raw | ConvertFrom-Json
      if ($null -ne $parsed) {
        $previousPackages = @($parsed)
      }
    }
    catch {
      Write-Warning "Invoke-BunSetup: manifest at '$manifestPath' could not be parsed; treating as empty"
    }
  }

  # Packages no longer desired that were previously managed by this module.
  $toRemove = @($previousPackages | Where-Object { $desiredPackages -notcontains $_ })

  # Desired packages whose binary is absent from ~\.bun\bin.
  # Derive the binary name from the package name: strip the scope prefix if
  # present (@scope/name → name) because bun uses the unscoped name for the bin.
  $toInstall = @($desiredPackages | Where-Object {
    $binName = ($_ -split '/')[-1]
    -not (
      (Test-Path (Join-Path $bunBinDir $binName)) -or
      (Test-Path (Join-Path $bunBinDir "$binName.exe")) -or
      (Test-Path (Join-Path $bunBinDir "$binName.cmd"))
    )
  })

  foreach ($pkg in $toRemove) {
    Write-Output "bun-setup: removing $pkg"
    bun remove -g $pkg
    if ($LASTEXITCODE -ne 0) {
      Write-Error "bun-setup: 'bun remove -g $pkg' failed (exit $LASTEXITCODE)"
      return
    }
  }

  foreach ($pkg in $toInstall) {
    Write-Output "bun-setup: installing $pkg"
    bun install -g $pkg
    if ($LASTEXITCODE -ne 0) {
      Write-Error "bun-setup: 'bun install -g $pkg' failed (exit $LASTEXITCODE)"
      return
    }
    $binName = ($pkg -split '/')[-1]
    if (-not (
      (Test-Path (Join-Path $bunBinDir $binName)) -or
      (Test-Path (Join-Path $bunBinDir "$binName.exe")) -or
      (Test-Path (Join-Path $bunBinDir "$binName.cmd"))
    )) {
      Write-Error "bun-setup: $pkg installed but binary '$binName' not found in '$bunBinDir'"
      return
    }
    Write-Output "bun-setup: $pkg installed successfully"
  }

  # Persist the current desired set as the new managed manifest so future
  # applies can compute removals when a package is dropped from the list.
  $manifestDir = Split-Path -Parent $manifestPath
  if (-not (Test-Path $manifestDir)) {
    New-Item -ItemType Directory -Path $manifestDir -Force | Out-Null
  }
  $desiredPackages | ConvertTo-Json | Set-Content -Path $manifestPath -Encoding UTF8
}
