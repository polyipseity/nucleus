#Requires -Version 7.4
# Windows lockfile version enforcement check step.
# Sources check-lib.ps1 (provides Write-Message, Write-WarningMessage,
# Write-ErrorMessage, Skip-Step, Get-StepNumber, Register-Step).
. (Join-Path $PSScriptRoot '..\check-lib.ps1')

Register-Step -Id "lockfile-enforcement" -Name "Lockfile version enforcement" -Action {
  param($HasArgs, $RepoRoot, $PositionalArgs)

  # Skip when scoped to files outside this step's scope (no lockfile JSON files).
  if ($HasArgs) {
    $hasLf = $false
    foreach ($f in $PositionalArgs) {
      if ($f -like '*lockfile*.json') { $hasLf = $true; break }
    }
    if (-not $hasLf) {
      Skip-Step -Number (Get-StepNumber) -Name "Lockfile version enforcement" -Reason "no lockfile files to check"
      return 2
    }
  }

  $lockfile = Join-Path $RepoRoot 'src\lockfiles\lockfile.json'
  if (-not (Test-Path $lockfile)) {
    Skip-Step -Number (Get-StepNumber) -Name "Lockfile version enforcement" -Reason "no lockfile present"
    return 2
  }

  $lf = $null
  try {
    $lf = Get-Content -Raw -Path $lockfile | ConvertFrom-Json -AsHashtable
  } catch {
    Write-ErrorMessage "lockfile.json could not be parsed: $_"
    return $false
  }
  if ($null -eq $lf) {
    Write-ErrorMessage "lockfile.json could not be read"
    return $false
  }

  $errors = 0

  # --- bun (global packages) ---
  if (Get-Command bun -ErrorAction SilentlyContinue) {
    $globalJson = Join-Path $env:USERPROFILE '.\bun\install\global\package.json'
    if (Test-Path $globalJson) {
      $installed = $null
      try { $installed = Get-Content -Raw -Path $globalJson | ConvertFrom-Json -AsHashtable } catch { $installed = $null }
      $bunSec = if ($lf.ContainsKey('bun')) { $lf.bun } else { @{} }
      foreach ($entry in $bunSec.GetEnumerator()) {
        $pkg = $entry.Key; $pin = $entry.Value
        if ($pin -is [hashtable]) { Write-Message "bun.$pkg`: VCS-pinned (rev) — not version-verifiable, skipping"; continue }
        $inst = if ($installed -and $installed.ContainsKey('dependencies') -and $installed.dependencies.ContainsKey($pkg)) { $installed.dependencies[$pkg] } else { $null }
        if ($null -eq $inst) { Write-ErrorMessage "bun.$pkg`: expected $pin, not installed"; $errors++ }
        elseif ($inst -ne $pin) { Write-ErrorMessage "bun.$pkg`: expected $pin, installed $inst"; $errors++ }
      }
    } else { Write-Message "bun: no global package.json; skipping" }
  } else { Write-Message "bun: not installed; skipping enforcement" }

  # --- uv (tools) ---
  if (Get-Command uv -ErrorAction SilentlyContinue) {
    $uvList = & uv tool list 2>$null
    $uvSec = if ($lf.ContainsKey('uv')) { $lf.uv } else { @{} }
    foreach ($entry in $uvSec.GetEnumerator()) {
      $tool = $entry.Key; $pin = $entry.Value
      if ($pin -is [hashtable]) { Write-Message "uv.$tool`: VCS-pinned (rev) — not version-verifiable, skipping"; continue }
      $inst = $null
      foreach ($line in $uvList) {
        if ($line -match "^$([regex]::Escape($tool))\s+v?(\d[\w.\-]*)") { $inst = $Matches[1]; break }
      }
      if ($null -eq $inst) { Write-ErrorMessage "uv.$tool`: expected $pin, not installed"; $errors++ }
      elseif ($inst -ne $pin) { Write-ErrorMessage "uv.$tool`: expected $pin, installed $inst"; $errors++ }
    }
  } else { Write-Message "uv: not installed; skipping enforcement" }

  # --- cargo-binstall (crates) ---
  if (Get-Command cargo -ErrorAction SilentlyContinue) {
    $cargoList = & cargo install --list 2>$null
    $cbSec = if ($lf.ContainsKey('cargo-binstall')) { $lf.'cargo-binstall' } else { @{} }
    foreach ($entry in $cbSec.GetEnumerator()) {
      $crate = $entry.Key; $pin = $entry.Value
      if ($pin -is [hashtable]) { Write-Message "cargo-binstall.$crate`: VCS-pinned (rev) — not version-verifiable, skipping"; continue }
      $inst = $null
      foreach ($line in $cargoList) {
        if ($line -match "^$([regex]::Escape($crate)) v(\d[\w.\-]*)") { $inst = $Matches[1]; break }
      }
      if ($null -eq $inst) { Write-ErrorMessage "cargo-binstall.$crate`: expected $pin, not installed"; $errors++ }
      elseif ($inst -ne $pin) { Write-ErrorMessage "cargo-binstall.$crate`: expected $pin, installed $inst"; $errors++ }
    }
  } else { Write-Message "cargo: not installed; skipping enforcement" }

  # --- rustup (stable toolchain) ---
  if (Get-Command rustup -ErrorAction SilentlyContinue) {
    $date = if ($lf.ContainsKey('rustup') -and $lf.rustup.ContainsKey('stable')) { $lf.rustup.stable } else { $null }
    if ($null -ne $date) {
      $spec = "stable-$date"
      $toolchains = & rustup toolchain list 2>$null
      $found = $false
      foreach ($line in $toolchains) { if ($line -match "^$([regex]::Escape($spec))") { $found = $true; break } }
      if (-not $found) { Write-ErrorMessage "rustup.stable: expected toolchain $spec not installed"; $errors++ }
    } else { Write-Message "rustup: no stable pin in lockfile; skipping" }
  } else { Write-Message "rustup: not installed; skipping enforcement" }

  # --- pwsh (modules) ---
  if (Get-Command pwsh -ErrorAction SilentlyContinue) {
    $pwshSec = if ($lf.ContainsKey('pwsh')) { $lf.pwsh } else { @{} }
    foreach ($entry in $pwshSec.GetEnumerator()) {
      $mod = $entry.Key; $pin = $entry.Value
      $inst = & pwsh -NoProfile -NonInteractive -Command "(Get-Module -ListAvailable -Name '$mod' | Select-Object -First 1).Version.ToString()" 2>$null
      if ([string]::IsNullOrWhiteSpace($inst)) { Write-ErrorMessage "pwsh.$mod`: expected $pin, not installed"; $errors++ }
      elseif ($inst.Trim() -ne $pin) { Write-ErrorMessage "pwsh.$mod`: expected $pin, installed $($inst.Trim())"; $errors++ }
    }
  } else { Write-Message "pwsh: not installed; skipping enforcement" }

  # --- scoop ---
  if (Get-Command scoop -ErrorAction SilentlyContinue) {
    $scoopList = & scoop list 2>$null
    $scoopSec = if ($lf.ContainsKey('scoop')) { $lf.scoop } else { @{} }
    foreach ($entry in $scoopSec.GetEnumerator()) {
      $app = $entry.Key; $pin = $entry.Value
      if ($pin -is [hashtable]) { Write-Message "scoop.$app`: VCS-pinned (rev) — not version-verifiable, skipping"; continue }
      $inst = $null
      foreach ($line in $scoopList) {
        if ($line -match "^$([regex]::Escape($app))\s+(\d[\w.\-]*)") { $inst = $Matches[1]; break }
      }
      if ($null -eq $inst) { Write-ErrorMessage "scoop.$app`: expected $pin, not installed"; $errors++ }
      elseif ($inst -ne $pin) { Write-ErrorMessage "scoop.$app`: expected $pin, installed $inst"; $errors++ }
    }
  } else { Write-Message "scoop: not installed; skipping enforcement" }

  # --- winget ---
  if (Get-Command winget -ErrorAction SilentlyContinue) {
    $wingetList = & winget list 2>$null
    $wingetSec = if ($lf.ContainsKey('winget')) { $lf.winget } else { @{} }
    foreach ($entry in $wingetSec.GetEnumerator()) {
      $app = $entry.Key; $pin = $entry.Value
      if ($pin -is [hashtable]) { Write-Message "winget.$app`: VCS-pinned (rev) — not version-verifiable, skipping"; continue }
      $inst = $null
      foreach ($line in $wingetList) {
        if ($line -match "^$([regex]::Escape($app))\s+(\d[\w.\-]*)") { $inst = $Matches[1]; break }
      }
      if ($null -eq $inst) { Write-ErrorMessage "winget.$app`: expected $pin, not installed"; $errors++ }
      elseif ($inst -ne $pin) { Write-ErrorMessage "winget.$app`: expected $pin, installed $inst"; $errors++ }
    }
  } else { Write-Message "winget: not installed; skipping enforcement" }

  # --- source-builds (VCS/rev pins are not version-verifiable) ---
  if ($lf.ContainsKey('source-builds')) {
    Write-Message "source-builds: VCS/rev-pinned — not version-verifiable, skipping enforcement"
  }

  # --- suggestions: always warn (non-authoritative) ---
  if ($lf.ContainsKey('suggestions')) {
    foreach ($sub in $lf.suggestions.Keys) {
      Write-WarningMessage "suggestions.$sub`: non-authoritative suggestion — not enforced (warn-only per invariant)"
    }
  }

  if ($errors -gt 0) {
    Write-ErrorMessage "lockfile enforcement found $errors pinned section(s) with version drift"
    return $false
  }
  Write-Message "lockfile enforcement: all applicable pinned sections match"
  return $true
}
