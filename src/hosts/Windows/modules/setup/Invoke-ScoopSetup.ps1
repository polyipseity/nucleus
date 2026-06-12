function Invoke-ScoopSetup {
  <#
  .SYNOPSIS
    Idempotently converges the declarative Scoop app set (install + prune).

  .DESCRIPTION
    Ensures the 'extras' and 'main' Scoop buckets are registered, then
    reads the Scoop apps directory for the actually installed set and removes
    anything not in the desired list (zap-style), then installs any desired
    apps that are missing at versions pinned in the repository lockfile.

    Mirrors the declarative install+prune approach used by Invoke-BunSetup and
    the installBunPackages POSIX activation.

    This function must run after the WinGet DSC step that installs Scoop.Scoop,
    because Scoop shims are written to %USERPROFILE%\scoop\shims which is not
    on PATH in the parent PowerShell session until explicitly prepended.

    Currently managed:
      - cargo-binstall — Rust CLI install vehicle; absent from WinGet; Scoop
                         main bucket is the correct tier
                         (winget > scoop > cargo binstall > bun > uv).
      - gopass         — cross-platform pass reimplementation; Windows parity
                         for pkgs.pass on POSIX hosts.
      - qemu           — QCOW2 tooling and guest VM runner for Invoke-VMSetup;
                         absent from WinGet; Scoop extras bucket.

  .EXAMPLE
    Invoke-ScoopSetup

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
  $scoopVersions = if ($lockfile -and $lockfile.scoop) { $lockfile.scoop } else { @{} }

  # Declarative desired-state list.  Add a package name here to install it;
  # remove it to trigger uninstall on the next apply.  Use the exact Scoop
  # app name.  Only add packages absent from WinGet.
  $desiredPackages = @(
    # Rust CLI install vehicle; absent from WinGet; Scoop main bucket is the
    # correct install tier (winget > scoop > cargo binstall > bun > uv).
    'cargo-binstall',
    # Cross-platform pass reimplementation; Windows parity for pkgs.pass;
    # absent from WinGet; Scoop main bucket.
    'gopass',
    # QCOW2 tooling and guest VM runner for Invoke-VMSetup; absent from
    # WinGet; Scoop extras bucket.
    'qemu',
    # Temporary keyboard locker for cleaning; blocks all input while you
    # wipe down the keyboard.  Press Ctrl+Break to unlock.
    # Usage: run 'iwck' from any terminal.
    'iwck'
  )

  # Prepend the Scoop shims directory so 'scoop' is resolvable in this session.
  # DSC runs in a child process; PATH additions from that process do not
  # propagate back to the parent shell, so the shims path must be added
  # explicitly here after the DSC step completes.
  $scoopShims = Join-Path $env:USERPROFILE "scoop\shims"
  if ($env:PATH -notlike "*$scoopShims*") {
    $env:PATH = "$scoopShims;$env:PATH"
  }

  if (-not (Test-Path (Join-Path $scoopShims "scoop.cmd"))) {
    Write-Error "Invoke-ScoopSetup: scoop not found at '$scoopShims\scoop.cmd'; ensure Scoop.Scoop was installed by WinGet DSC before calling this function"
    return
  }

  # Ensure required buckets are registered.  'main' is the default bucket but
  # may be absent on a fresh Scoop install depending on the version.  'extras'
  # hosts qemu and is registered as a standard supplement bucket.
  foreach ($bucket in @('extras', 'main')) {
    # -ErrorAction SilentlyContinue is intentional: 'scoop bucket list' may
    # exit non-zero when no buckets are registered yet (fresh install).
    # The result string is checked immediately by the -notmatch guard.
    $existing = scoop bucket list 2>&1
    if ($existing -notmatch "(?m)^$bucket\b") {
      Write-Output "scoop: adding bucket '$bucket'"
      scoop bucket add $bucket
      if ($LASTEXITCODE -ne 0) {
        Write-Error "scoop: failed to add bucket '$bucket' (exit $LASTEXITCODE)"
        return
      }
    }
  }

  # Get actually installed Scoop apps by reading the apps directory (zap-style:
  # remove any installed app absent from the desired list, regardless of prior
  # managed state).  Scoop installs each app to ~\scoop\apps\<name>\, so
  # directory names are the authoritative installed set.
  $scoopAppsDir = Join-Path $env:USERPROFILE "scoop\apps"
  $installedApps = @()
  if (Test-Path $scoopAppsDir) {
    $installedApps = @(
      Get-ChildItem -Path $scoopAppsDir -Directory |
        Select-Object -ExpandProperty Name
    )
  }

  # Parse installed versions from `scoop list` for version reconciliation.
  $installedVersions = @{}
  $scoopListOutput = @(scoop list 2>&1)
  $scoopListOutput | Select-String "^'(.+)' \((\S+)\)" | ForEach-Object {
    $installedVersions[$_.Matches.Groups[1].Value] = $_.Matches.Groups[2].Value
  }

  # Apps installed but not desired: zap-style removal.
  # Mirrors homebrew cleanup = "zap": removes anything installed but absent
  # from the declared desired set, regardless of how it was installed.
  $toRemove = @($installedApps | Where-Object { $desiredPackages -notcontains $_ })

  # Desired apps not yet installed OR installed at a version different from
  # the lockfile pin (version-aware reconciliation).  Scoop writes a
  # <name>.cmd shim for most apps; fall back to <name>.exe for apps (like
  # gopass) that ship a native binary shim.
  $toInstall = @($desiredPackages | Where-Object {
    $pkg = $_
    $isInstalled = $installedApps -contains $pkg
    if (-not $isInstalled) { return $true }
    $expectedVersion = $scoopVersions.$pkg
    if (-not $expectedVersion) { return $false }
    $installedVersion = $installedVersions[$pkg]
    $installedVersion -ne $expectedVersion
  })

  # Prune packages removed from the desired list.
  foreach ($pkg in $toRemove) {
    Write-Output "scoop: uninstalling removed package '$pkg'"
    scoop uninstall $pkg
    if ($LASTEXITCODE -ne 0) {
      Write-Error "scoop: 'scoop uninstall $pkg' failed (exit $LASTEXITCODE)"
      return
    }
    Write-Output "scoop: '$pkg' uninstalled"
  }

  # Install additions with version pinning from lockfile.
  foreach ($pkg in $toInstall) {
    $version = $scoopVersions.$pkg
    $installSpec = if ($version) { "$pkg@$version" } else { $pkg }
    Write-Output "scoop: installing '$installSpec'"
    scoop install $installSpec
    if ($LASTEXITCODE -ne 0) {
      Write-Error "scoop: 'scoop install $installSpec' failed (exit $LASTEXITCODE)"
      return
    }
    if (-not (Test-Path (Join-Path $scoopShims "$pkg.cmd")) -and
        -not (Test-Path (Join-Path $scoopShims "$pkg.exe"))) {
      Write-Error "scoop: '$pkg' installed but no shim found under '$scoopShims'"
      return
    }
    Write-Output "scoop: '$pkg' installed successfully"
  }

  # Hold all managed packages at their locked versions (prevents accidental upgrades).
  foreach ($pkg in $desiredPackages) {
    scoop hold $pkg 2>&1 | Out-Null
  }

  if ($toInstall.Count -eq 0 -and $toRemove.Count -eq 0) {
    Write-Output "scoop: all managed packages already converged — skipping"
  }

}
