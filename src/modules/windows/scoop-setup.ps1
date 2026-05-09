# modules/windows/scoop-setup.ps1 — Scoop bucket and app provisioning for Windows.
#
# Idempotently ensures the main and extras Scoop buckets exist and installs
# cargo-binstall from the Scoop main bucket.  cargo-binstall occupies the
# third tier of the install preference hierarchy
# (winget > scoop > cargo binstall > bun) for Rust CLI tools absent from
# WinGet and Scoop; it is itself only available via Scoop on Windows.

function Invoke-ScoopSetup {
  <#
  .SYNOPSIS
    Idempotently provisions Scoop buckets and installs managed Scoop apps.

  .DESCRIPTION
    Ensures the 'main' and 'extras' Scoop buckets are registered, then
    installs cargo-binstall from the Scoop main bucket if it is not already
    present.  cargo-binstall is not available in WinGet, making Scoop the
    correct install channel per the repository preference hierarchy
    (nixpkgs/winget > scoop > cargo binstall).

    Also installs gopass (the cross-platform Go reimplementation of the Unix
    pass password manager) from the Scoop main bucket for Windows parity
    with pkgs.pass on POSIX hosts.  No WinGet package exists for gopass; Scoop
    is the correct install tier.

    This function must run after the WinGet DSC step that installs Scoop.Scoop,
    because Scoop shims are written to %USERPROFILE%\scoop\shims which is not
    on PATH in the parent PowerShell session until explicitly prepended.

    Safe to call on every apply: all install and bucket operations are guarded
    by existence checks so repeated runs are no-ops when state is already correct.

  .EXAMPLE
    Invoke-ScoopSetup
  #>
  [CmdletBinding()]
  param()

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
  # is registered as a standard supplement bucket for future tool additions.
  foreach ($bucket in @('extras', 'main')) {
    # -ErrorAction SilentlyContinue is intentional: 'scoop bucket list' may
    # exit non-zero when no buckets are registered yet (fresh install).
    # The result string is checked immediately by the -notmatch guard.
    $existing = scoop bucket list 2>&1
    if ($existing -notmatch "(?m)^$bucket\b") {
      Write-Host "scoop: adding bucket '$bucket'"
      scoop bucket add $bucket
      if ($LASTEXITCODE -ne 0) {
        Write-Error "scoop: failed to add bucket '$bucket' (exit $LASTEXITCODE)"
        return
      }
    }
  }

  # Install cargo-binstall if the shim is not yet present.  cargo-binstall is
  # available in the Scoop main bucket and NOT available in WinGet, making
  # Scoop the correct install channel per the repository preference hierarchy
  # (nixpkgs/winget > scoop > cargo binstall).  The shim file is the reliable
  # post-install artefact; checking it avoids running 'scoop status' which
  # requires network access.
  $cbBin = Join-Path $scoopShims "cargo-binstall.cmd"
  if (-not (Test-Path $cbBin)) {
    Write-Host "scoop: installing cargo-binstall"
    scoop install cargo-binstall
    if ($LASTEXITCODE -ne 0) {
      Write-Error "scoop: 'scoop install cargo-binstall' failed (exit $LASTEXITCODE)"
      return
    }
    if (-not (Test-Path $cbBin)) {
      Write-Error "scoop: cargo-binstall installed but shim not found at '$cbBin'"
      return
    }
    Write-Host "scoop: cargo-binstall installed successfully"
  } else {
    Write-Host "scoop: cargo-binstall already installed — skipping"
  }

  # Install gopass if the shim is not yet present.  gopass is the cross-platform
  # Go reimplementation of the Unix pass password manager; it is the Windows
  # equivalent of pkgs.pass used on POSIX hosts.  No WinGet package exists;
  # Scoop main bucket is the correct install tier per the repository preference
  # hierarchy (winget > scoop > cargo binstall > bun).
  $gopassBin = Join-Path $scoopShims "gopass.exe"
  if (-not (Test-Path $gopassBin)) {
    Write-Host "scoop: installing gopass"
    scoop install gopass
    if ($LASTEXITCODE -ne 0) {
      Write-Error "scoop: 'scoop install gopass' failed (exit $LASTEXITCODE)"
      return
    }
    if (-not (Test-Path $gopassBin)) {
      Write-Error "scoop: gopass installed but binary not found at '$gopassBin'"
      return
    }
    Write-Host "scoop: gopass installed successfully"
  } else {
    Write-Host "scoop: gopass already installed — skipping"
  }
}
