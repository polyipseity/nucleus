# modules/Windows/uv-setup.ps1 — Declarative uv tool management for Windows.
#
# Installs and removes Python CLI tools via `uv tool install` for tools that are
# not available in WinGet, Scoop, cargo-binstall, or bun.  uv occupies the last
# tier of the repository install preference hierarchy:
#   nixpkgs/winget > scoop > cargo binstall > bun > uv
# uv itself is installed from WinGet (astral-sh.uv in system.dsc.yml).
#
# Mirrors the installUvTools POSIX activation in agents.nix.

function Invoke-UvSetup {
  <#
  .SYNOPSIS
    Idempotently converges the declarative uv tool set (install + prune).

  .DESCRIPTION
    Maintains a managed set of Python CLI tools installed via `uv tool install`.
    On each apply it computes the diff between the desired package list and a
    per-user manifest at %USERPROFILE%\.config\nucleus\uv-tools.json, installs
    additions via `uv tool install`, and removes deletions via `uv tool uninstall`.

    Requires uv to be on PATH (installed from WinGet by system.dsc.yml).
    Prepends %USERPROFILE%\.local\bin to PATH internally so uv-installed
    binaries are accessible in subsequent steps of the same apply session.

  .EXAMPLE
    Invoke-UvSetup
  #>
  [CmdletBinding()]
  param()

  # Declarative desired-state list.  Add a package name here to install it;
  # remove it to trigger uninstall on the next apply.  Use the exact PyPI
  # package name.  Only add packages absent from WinGet, Scoop, and
  # cargo-binstall.
  $desiredPackages = @(
    # No uv-managed tools yet.  Add entries here as needed.
  )

  # uv tool install places binaries in ~\.local\bin by default (UV_TOOL_BIN_DIR).
  $uvBinDir = Join-Path $HOME ".local\bin"
  $manifestPath = Join-Path $HOME ".config\nucleus\uv-tools.json"
  $manifestDir = Split-Path $manifestPath -Parent

  # Guard: uv must be accessible after WinGet DSC has installed astral-sh.uv.
  if (-not (Get-Command uv -ErrorAction SilentlyContinue)) {
    # -ErrorAction SilentlyContinue is intentional: absence of uv is an
    # expected probe condition; the if-guard checks the result immediately.
    Write-Error "Invoke-UvSetup: uv not found on PATH; ensure astral-sh.uv was installed by WinGet DSC before calling this function"
    return
  }

  # Prepend ~/.local/bin so binaries installed during this apply run are
  # accessible in subsequent steps without opening a new terminal session.
  if ($env:PATH -notlike "*$uvBinDir*") {
    $env:PATH = "$uvBinDir;$env:PATH"
  }

  # Read the previously-managed package list.  An absent or malformed manifest
  # (first run) is treated as an empty set so all desired packages become
  # additions and nothing is pruned unexpectedly.
  $previousPackages = @()
  if (Test-Path $manifestPath) {
    try {
      $parsed = Get-Content -Path $manifestPath -Raw | ConvertFrom-Json
      if ($null -ne $parsed) {
        $previousPackages = @($parsed)
      }
    }
    catch {
      Write-Warning "Invoke-UvSetup: manifest at '$manifestPath' could not be parsed; treating as empty"
    }
  }

  # Packages no longer desired: present in the previous manifest but absent
  # from the desired list.
  $toRemove = @($previousPackages | Where-Object { $desiredPackages -notcontains $_ })

  # Desired packages whose binary is absent from ~\.local\bin.
  $toInstall = @($desiredPackages | Where-Object {
    $pkg = $_
    # uv tool install uses the package name as the binary name by default.
    -not (Test-Path (Join-Path $uvBinDir "$pkg.exe")) -and
    -not (Test-Path (Join-Path $uvBinDir $pkg))
  })

  # Prune packages removed from the desired list.
  foreach ($pkg in $toRemove) {
    Write-Output "uv: uninstalling removed tool '$pkg'"
    uv tool uninstall $pkg
    if ($LASTEXITCODE -ne 0) {
      Write-Error "uv: 'uv tool uninstall $pkg' failed (exit $LASTEXITCODE)"
      return
    }
    Write-Output "uv: '$pkg' uninstalled"
  }

  # Install additions.
  foreach ($pkg in $toInstall) {
    Write-Output "uv: installing tool '$pkg'"
    uv tool install $pkg
    if ($LASTEXITCODE -ne 0) {
      Write-Error "uv: 'uv tool install $pkg' failed (exit $LASTEXITCODE)"
      return
    }
    Write-Output "uv: '$pkg' installed successfully"
  }

  if ($toInstall.Count -eq 0 -and $toRemove.Count -eq 0) {
    Write-Output "uv: all managed tools already converged — skipping"
  }

  # Persist the new desired set so the next apply can detect future removals.
  if (-not (Test-Path $manifestDir)) {
    New-Item -ItemType Directory -Path $manifestDir -Force | Out-Null
  }
  $desiredPackages | ConvertTo-Json -Compress | Set-Content -Path $manifestPath -Encoding UTF8
}
