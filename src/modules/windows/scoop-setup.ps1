# modules/windows/scoop-setup.ps1 — Scoop bucket and app provisioning for Windows.
#
# Idempotently ensures the main and extras Scoop buckets exist and installs
# thefuck for cross-host shell correction parity with macOS and NixOS.

function Invoke-ScoopSetup {
  <#
  .SYNOPSIS
    Idempotently provisions Scoop buckets and installs managed Scoop apps.

  .DESCRIPTION
    Ensures the 'main' and 'extras' Scoop buckets are registered, then
    installs thefuck if it is not already present.

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
  # is required for thefuck.
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

  # Install thefuck if the shim is not yet present.  The shim file is the
  # reliable post-install artefact; checking it avoids running 'scoop status'
  # which requires network access.
  $tfBin = Join-Path $scoopShims "thefuck.cmd"
  if (-not (Test-Path $tfBin)) {
    Write-Host "scoop: installing thefuck"
    scoop install thefuck
    if ($LASTEXITCODE -ne 0) {
      Write-Error "scoop: 'scoop install thefuck' failed (exit $LASTEXITCODE)"
      return
    }
    if (-not (Test-Path $tfBin)) {
      Write-Error "scoop: thefuck installed but binary not found at '$tfBin'"
      return
    }
    Write-Host "scoop: thefuck installed successfully"
  } else {
    Write-Host "scoop: thefuck already installed — skipping"
  }
}
