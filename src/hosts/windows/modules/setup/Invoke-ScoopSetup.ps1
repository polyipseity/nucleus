# modules/windows/scoop-setup.ps1 — Declarative Scoop bucket and app management.
#
# Idempotently converges the declared set of Scoop apps and prunes removed
# entries from a per-user manifest at %USERPROFILE%\.config\nucleus\scoop-packages.json.
# Mirrors the declarative install+prune approach used by Invoke-BunSetup and the
# installBunPackages POSIX activation.

function Invoke-ScoopSetup {
  <#
  .SYNOPSIS
    Idempotently converges the declarative Scoop app set (install + prune).

  .DESCRIPTION
    Ensures the 'extras' and 'main' Scoop buckets are registered, then
    converges the managed Scoop app set:
      - Installs additions listed in $desiredPackages but absent from Scoop.
      - Uninstalls packages present in the previous manifest but no longer
        declared, mirroring the prune behaviour of Invoke-BunSetup.
    The manifest at %USERPROFILE%\.config\nucleus\scoop-packages.json records
    the current managed set so subsequent runs can detect deletions.

    This function must run after the WinGet DSC step that installs Scoop.Scoop,
    because Scoop shims are written to %USERPROFILE%\scoop\shims which is not
    on PATH in the parent PowerShell session until explicitly prepended.

    Currently managed:
      - cargo-binstall — Rust CLI install vehicle; absent from WinGet; Scoop
                         main bucket is the correct tier
                         (winget > scoop > cargo binstall > bun).
      - gopass         — cross-platform pass reimplementation; Windows parity
                         for pkgs.pass on POSIX hosts.
      - qemu           — QCOW2 tooling and guest VM runner for Invoke-VMSetup;
                         absent from WinGet; Scoop extras bucket.

  .EXAMPLE
    Invoke-ScoopSetup
  #>
  [CmdletBinding()]
  param()

  # Declarative desired-state list.  Add a package name here to install it;
  # remove it to trigger uninstall on the next apply.  Use the exact Scoop
  # app name.  Only add packages absent from WinGet.
  $desiredPackages = @(
    # Rust CLI install vehicle; absent from WinGet; Scoop main bucket is the
    # correct install tier (winget > scoop > cargo binstall > bun).
    'cargo-binstall',
    # Cross-platform pass reimplementation; Windows parity for pkgs.pass;
    # absent from WinGet; Scoop main bucket.
    'gopass',
    # QCOW2 tooling and guest VM runner for Invoke-VMSetup; absent from
    # WinGet; Scoop extras bucket.
    'qemu'
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

  $manifestPath = Join-Path $HOME ".config\nucleus\scoop-packages.json"
  $manifestDir = Split-Path $manifestPath -Parent

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
      Write-Warning "Invoke-ScoopSetup: manifest at '$manifestPath' could not be parsed; treating as empty"
    }
  }

  # Packages no longer desired: present in the previous manifest but absent
  # from the desired list.
  $toRemove = @($previousPackages | Where-Object { $desiredPackages -notcontains $_ })

  # Desired packages not yet installed (shim absent from scoopShims).
  # Scoop writes a <name>.cmd shim for most apps; fall back to <name>.exe for
  # apps (like gopass) that ship a native binary shim.
  $toInstall = @($desiredPackages | Where-Object {
    $pkg = $_
    -not (Test-Path (Join-Path $scoopShims "$pkg.cmd")) -and
    -not (Test-Path (Join-Path $scoopShims "$pkg.exe"))
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

  # Install additions.
  foreach ($pkg in $toInstall) {
    Write-Output "scoop: installing '$pkg'"
    scoop install $pkg
    if ($LASTEXITCODE -ne 0) {
      Write-Error "scoop: 'scoop install $pkg' failed (exit $LASTEXITCODE)"
      return
    }
    if (-not (Test-Path (Join-Path $scoopShims "$pkg.cmd")) -and
        -not (Test-Path (Join-Path $scoopShims "$pkg.exe"))) {
      Write-Error "scoop: '$pkg' installed but no shim found under '$scoopShims'"
      return
    }
    Write-Output "scoop: '$pkg' installed successfully"
  }

  if ($toInstall.Count -eq 0 -and $toRemove.Count -eq 0) {
    Write-Output "scoop: all managed packages already converged — skipping"
  }

  # Persist the new desired set so the next apply can detect future removals.
  if (-not (Test-Path $manifestDir)) {
    New-Item -ItemType Directory -Path $manifestDir -Force | Out-Null
  }
  $desiredPackages | ConvertTo-Json -Compress | Set-Content -Path $manifestPath -Encoding UTF8
}
