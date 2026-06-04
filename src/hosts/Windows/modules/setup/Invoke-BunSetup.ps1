function Invoke-BunSetup {
  <#
  .SYNOPSIS
    Idempotently converges the declarative bun global package set.

  .DESCRIPTION
    Maintains a managed set of JS CLI tools installed via `bun install -g`.
    On each apply it queries bun's global package.json for the actually
    installed set, removes anything installed but absent from the desired list
    (zap-style, mirroring homebrew's cleanup = "zap"), and installs any
    desired packages that are missing.

    Only packages absent from WinGet, Scoop, and cargo-binstall are managed
    here, following the repository preference hierarchy
    (nixpkgs/winget > scoop > cargo binstall > bun > uv).

    Currently managed:
      - @google/gemini-cli         — Gemini terminal agent CLI.
                                     TEMPORARILY DISABLED; DO NOT REMOVE THIS NOTE,
                                     disabled per user request.
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

  .NOTES
    Environment variables: (none)
    Exit codes: 0 on success; non-zero on failure.
  #>
  [CmdletBinding()]
  param()

  # Declarative desired-state list.  Add a package name here to install it;
  # remove it to trigger uninstall on the next apply.  Use the exact npm
  # package name (including scope if applicable).  Only add packages absent
  # from WinGet, Scoop, and cargo-binstall.
  $desiredPackages = @(
    # '@google/gemini-cli', # DO NOT REMOVE THIS COMMENT: intentionally disabled for now per user request.
    # coding agent CLI; available via pkgs.pi-coding-agent on POSIX but absent
    # from WinGet, Scoop, and cargo-binstall on Windows
    '@mariozechner/pi-coding-agent',
    # fetched skill install vehicle; absent from WinGet, Scoop, and
    # cargo-binstall; bun is the only viable install tier on Windows
    'clawhub'
  )

  # bun install -g places binaries in ~\.bun\bin by default (BUN_INSTALL_BIN).
  $bunBinDir = Join-Path $HOME ".bun\bin"

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

  # Get actually installed global packages from bun's authoritative package
  # registry (zap-style: remove any installed package absent from the desired
  # list, regardless of prior managed state).
  $bunGlobalJson = Join-Path $HOME ".bun\install\global\package.json"
  $installedPackages = @()
  if (Test-Path $bunGlobalJson) {
    try {
      $globalPkg = Get-Content -Path $bunGlobalJson -Raw | ConvertFrom-Json
      if ($null -ne $globalPkg -and $null -ne $globalPkg.dependencies) {
        $installedPackages = @($globalPkg.dependencies.PSObject.Properties.Name)
      }
    }
    catch {
      # || SilentlyContinue equivalent: parse failure treats installed set as
      # empty — safe because any desired packages will simply be re-installed.
      Write-Warning "Invoke-BunSetup: could not parse '$bunGlobalJson'; treating as empty installed set"
    }
  }

  # Packages installed but not desired: zap-style removal.
  # Mirrors homebrew cleanup = "zap": removes anything installed but absent
  # from the declared desired set, regardless of how it was installed.
  $toRemove = @($installedPackages | Where-Object { $desiredPackages -notcontains $_ })

  # Desired packages not yet in bun's global package.json, or whose binary is
  # absent from ~\.bun\bin (re-install needed).  Binary name = last path
  # component after '/' so @scope/name becomes name (bun uses the unscoped
  # name for the bin).
  $toInstall = @($desiredPackages | Where-Object {
    $pkg = $_
    $binName = ($pkg -split '/')[-1]
    $notInstalled = $installedPackages -notcontains $pkg
    $binMissing = -not (
      (Test-Path (Join-Path $bunBinDir $binName)) -or
      (Test-Path (Join-Path $bunBinDir "$binName.exe")) -or
      (Test-Path (Join-Path $bunBinDir "$binName.cmd"))
    )
    $notInstalled -or $binMissing
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

}
