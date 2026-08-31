#Requires -Version 7.4
# Shared lockfile enforcement probes for both the check step and
# bump-lockfile.ps1 -VerifyInstalled.  Does NOT depend on check-lib.ps1
# (no Skip-Step / Get-StepNumber), so it is safe to source from bump-lockfile.
#
# Message output is delegated via scriptblock parameters so the same probe
# logic serves both the check step (Write-Message / Write-WarningMessage /
# Write-ErrorMessage) and bump-lockfile.ps1 (Write-NucleusInfo / etc.).
function Invoke-LockfileEnforcement {
  [CmdletBinding()]
  [OutputType([int])]
  param(
    [Parameter(Mandatory = $true)]
    [hashtable]$Lockfile,
    [scriptblock]$InfoFn = { param($m) Write-Output $m },
    [scriptblock]$WarnFn = { param($m) Write-Output "warning: $m" },
    [scriptblock]$ErrorFn = { param($m) Write-Output "error: $m" }
  )

  $errors = 0

  # --- bun (global packages) ---
  if (Get-Command bun -ErrorAction SilentlyContinue) {  # check-suppress:suppression_doc: tool may not be installed on this host; the else branch reports the skip
    $globalJson = Join-Path $env:USERPROFILE '.\bun\install\global\package.json'
    if (Test-Path $globalJson) {
      $installed = $null
      try { $installed = Get-Content -Raw -Path $globalJson | ConvertFrom-Json -AsHashtable } catch { $installed = $null }
      $bunSec = if ($Lockfile.ContainsKey('bun')) { $Lockfile.bun } else { @{} }
      foreach ($entry in $bunSec.GetEnumerator()) {
        $pkg = $entry.Key; $pin = $entry.Value
        if ($pin -is [hashtable]) { & $InfoFn "bun.$pkg`: VCS-pinned (rev) — not version-verifiable, skipping"; continue }
        $inst = if ($installed -and $installed.ContainsKey('dependencies') -and $installed.dependencies.ContainsKey($pkg)) { $installed.dependencies[$pkg] } else { $null }
        if ($null -eq $inst) { & $ErrorFn "bun.$pkg`: expected $pin, not installed"; $errors++ }
        elseif ($inst -ne $pin) { & $ErrorFn "bun.$pkg`: expected $pin, installed $inst"; $errors++ }
      }
    } else { & $InfoFn "bun: no global package.json; skipping" }
  } else { & $InfoFn "bun: not installed; skipping enforcement" }

  # --- uv (tools) ---
  if (Get-Command uv -ErrorAction SilentlyContinue) {  # check-suppress:suppression_doc: tool may not be installed on this host; the else branch reports the skip
    $uvList = & uv tool list 2>$null  # check-suppress:suppression_doc: list command may emit noise/errors when the tool store is uninitialised; empty output is treated as no-installs and drift is still reported below
    $uvSec = if ($Lockfile.ContainsKey('uv')) { $Lockfile.uv } else { @{} }
    foreach ($entry in $uvSec.GetEnumerator()) {
      $tool = $entry.Key; $pin = $entry.Value
      if ($pin -is [hashtable]) { & $InfoFn "uv.$tool`: VCS-pinned (rev) — not version-verifiable, skipping"; continue }
      $inst = $null
      foreach ($line in $uvList) {
        if ($line -match "^$([regex]::Escape($tool))\s+v?(\d[\w.\-]*)") { $inst = $Matches[1]; break }
      }
      if ($null -eq $inst) { & $ErrorFn "uv.$tool`: expected $pin, not installed"; $errors++ }
      elseif ($inst -ne $pin) { & $ErrorFn "uv.$tool`: expected $pin, installed $inst"; $errors++ }
    }
  } else { & $InfoFn "uv: not installed; skipping enforcement" }

  # --- cargo-binstall (crates) ---
  if (Get-Command cargo -ErrorAction SilentlyContinue) {  # check-suppress:suppression_doc: tool may not be installed on this host; the else branch reports the skip
    $cargoList = & cargo install --list 2>$null  # check-suppress:suppression_doc: list command may emit noise/errors when the tool store is uninitialised; empty output is treated as no-installs and drift is still reported below
    $cbSec = if ($Lockfile.ContainsKey('cargo-binstall')) { $Lockfile.'cargo-binstall' } else { @{} }
    foreach ($entry in $cbSec.GetEnumerator()) {
      $crate = $entry.Key; $pin = $entry.Value
      if ($pin -is [hashtable]) { & $InfoFn "cargo-binstall.$crate`: VCS-pinned (rev) — not version-verifiable, skipping"; continue }
      $inst = $null
      foreach ($line in $cargoList) {
        if ($line -match "^$([regex]::Escape($crate)) v(\d[\w.\-]*)") { $inst = $Matches[1]; break }
      }
      if ($null -eq $inst) { & $ErrorFn "cargo-binstall.$crate`: expected $pin, not installed"; $errors++ }
      elseif ($inst -ne $pin) { & $ErrorFn "cargo-binstall.$crate`: expected $pin, installed $inst"; $errors++ }
    }
  } else { & $InfoFn "cargo: not installed; skipping enforcement" }

  # --- rustup (stable toolchain) ---
  if (Get-Command rustup -ErrorAction SilentlyContinue) {  # check-suppress:suppression_doc: tool may not be installed on this host; the else branch reports the skip
    $date = if ($Lockfile.ContainsKey('rustup') -and $Lockfile.rustup.ContainsKey('stable')) { $Lockfile.rustup.stable } else { $null }
    if ($null -ne $date) {
      $spec = "stable-$date"
      $toolchains = & rustup toolchain list 2>$null  # check-suppress:suppression_doc: list command may emit noise/errors when the tool store is uninitialised; empty output is treated as no-installs and drift is still reported below
      $found = $false
      foreach ($line in $toolchains) { if ($line -match "^$([regex]::Escape($spec))") { $found = $true; break } }
      if (-not $found) { & $ErrorFn "rustup.stable: expected toolchain $spec not installed"; $errors++ }
    } else { & $InfoFn "rustup: no stable pin in lockfile; skipping" }
  } else { & $InfoFn "rustup: not installed; skipping enforcement" }

  # --- pwsh (modules) ---
  if (Get-Command pwsh -ErrorAction SilentlyContinue) {  # check-suppress:suppression_doc: tool may not be installed on this host; the else branch reports the skip
    $pwshSec = if ($Lockfile.ContainsKey('pwsh')) { $Lockfile.pwsh } else { @{} }
    foreach ($entry in $pwshSec.GetEnumerator()) {
      $mod = $entry.Key; $pin = $entry.Value
      $inst = & pwsh -NoProfile -NonInteractive -Command "(Get-Module -ListAvailable -Name '$mod' | Select-Object -First 1).Version.ToString()" 2>$null  # check-suppress:suppression_doc: list command may emit noise/errors when the tool store is uninitialised; empty output is treated as no-installs and drift is still reported below
      if ([string]::IsNullOrWhiteSpace($inst)) { & $ErrorFn "pwsh.$mod`: expected $pin, not installed"; $errors++ }
      elseif ($inst.Trim() -ne $pin) { & $ErrorFn "pwsh.$mod`: expected $pin, installed $($inst.Trim())"; $errors++ }
    }
  } else { & $InfoFn "pwsh: not installed; skipping enforcement" }

  # --- scoop ---
  if (Get-Command scoop -ErrorAction SilentlyContinue) {  # check-suppress:suppression_doc: tool may not be installed on this host; the else branch reports the skip
    $scoopList = & scoop list 2>$null  # check-suppress:suppression_doc: list command may emit noise/errors when the tool store is uninitialised; empty output is treated as no-installs and drift is still reported below
    $scoopSec = if ($Lockfile.ContainsKey('scoop')) { $Lockfile.scoop } else { @{} }
    foreach ($entry in $scoopSec.GetEnumerator()) {
      $app = $entry.Key; $pin = $entry.Value
      if ($pin -is [hashtable]) { & $InfoFn "scoop.$app`: VCS-pinned (rev) — not version-verifiable, skipping"; continue }
      $inst = $null
      foreach ($line in $scoopList) {
        if ($line -match "^$([regex]::Escape($app))\s+(\d[\w.\-]*)") { $inst = $Matches[1]; break }
      }
      if ($null -eq $inst) { & $ErrorFn "scoop.$app`: expected $pin, not installed"; $errors++ }
      elseif ($inst -ne $pin) { & $ErrorFn "scoop.$app`: expected $pin, installed $inst"; $errors++ }
    }
  } else { & $InfoFn "scoop: not installed; skipping enforcement" }

  # --- winget ---
  if (Get-Command winget -ErrorAction SilentlyContinue) {  # check-suppress:suppression_doc: tool may not be installed on this host; the else branch reports the skip
    $wingetList = & winget list 2>$null  # check-suppress:suppression_doc: list command may emit noise/errors when the tool store is uninitialised; empty output is treated as no-installs and drift is still reported below
    $wingetSec = if ($Lockfile.ContainsKey('winget')) { $Lockfile.winget } else { @{} }
    foreach ($entry in $wingetSec.GetEnumerator()) {
      $app = $entry.Key; $pin = $entry.Value
      if ($pin -is [hashtable]) { & $InfoFn "winget.$app`: VCS-pinned (rev) — not version-verifiable, skipping"; continue }
      $inst = $null
      foreach ($line in $wingetList) {
        if ($line -match "^$([regex]::Escape($app))\s+(\d[\w.\-]*)") { $inst = $Matches[1]; break }
      }
      if ($null -eq $inst) { & $ErrorFn "winget.$app`: expected $pin, not installed"; $errors++ }
      elseif ($inst -ne $pin) { & $ErrorFn "winget.$app`: expected $pin, installed $inst"; $errors++ }
    }
  } else { & $InfoFn "winget: not installed; skipping enforcement" }

  # --- source-builds (VCS/rev pins are not version-verifiable) ---
  if ($Lockfile.ContainsKey('source-builds')) {
    & $InfoFn "source-builds: VCS/rev-pinned — not version-verifiable, skipping enforcement"
  }

  # --- suggestions.opencode (warn-only, not version-verifiable) ---
  # opencode is a suggestions section (warn-only per the invariant).  Plugins
  # use git+URL format with no installed-version query mechanism.  Report
  # info-level skip for each entry.  Never errors.
  if ($Lockfile.ContainsKey('suggestions') -and $Lockfile.suggestions.ContainsKey('opencode')) {
    foreach ($entry in $Lockfile.suggestions.opencode.Keys) {
      & $InfoFn "suggestions.opencode.$entry`: VCS-pinned — not version-verifiable, skipping"
    }
  }

  # --- suggestions.vscode (warn-only verify probe) ---
  # vscode is a suggestions section (warn-only per the invariant) and is not
  # actually locked on all platforms (POSIX locks via flake.lock).  Compare
  # installed extension versions to the lockfile map; never error.  Skip
  # gracefully when no code CLI is installed.
  $codeExe = $null
  if (Get-Command code -ErrorAction SilentlyContinue) { $codeExe = 'code' }  # check-suppress:suppression_doc: tool may not be installed on this host; the else branch reports the skip
  elseif (Get-Command code-insiders -ErrorAction SilentlyContinue) { $codeExe = 'code-insiders' }  # check-suppress:suppression_doc: tool may not be installed on this host; the else branch reports the skip
  if ($null -ne $codeExe) {
    $installedList = & $codeExe --list-extensions --show-versions 2>$null  # check-suppress:suppression_doc: list command may emit noise/errors when the tool store is uninitialised; empty output is treated as no-installs and drift is still reported below
    $vscodeSec = if ($Lockfile.ContainsKey('suggestions') -and $Lockfile.suggestions.ContainsKey('vscode')) { $Lockfile.suggestions.vscode } else { @{} }
    foreach ($entry in $vscodeSec.GetEnumerator()) {
      $ext = $entry.Key; $pin = $entry.Value
      $inst = $null
      foreach ($line in $installedList) {
        if ($line -match "^$([regex]::Escape($ext))@(.+)") { $inst = $Matches[1]; break }
      }
      if ($null -eq $inst) { & $WarnFn "suggestions.vscode.$ext`: expected $pin, not installed (warn-only)" }
      elseif ($inst -ne $pin) { & $WarnFn "suggestions.vscode.$ext`: expected $pin, installed $inst (warn-only)" }
    }
  } else { & $InfoFn "vscode: no code CLI; skipping suggestions.vscode verify" }

  # --- suggestions.cursor (warn-only verify probe) ---
  # cursor is a suggestions section (warn-only per the invariant).  Compare
  # installed extension versions to the lockfile map; never error.  Skip
  # gracefully when no cursor CLI is installed.
  $cursorExe = $null
  if (Get-Command cursor -ErrorAction SilentlyContinue) { $cursorExe = 'cursor' }  # check-suppress:suppression_doc: tool may not be installed on this host; the else branch reports the skip
  if ($null -ne $cursorExe) {
    $installedList = & $cursorExe --list-extensions --show-versions 2>$null  # check-suppress:suppression_doc: list command may emit noise/errors when the tool store is uninitialised; empty output is treated as no-installs and drift is still reported below
    $cursorSec = if ($Lockfile.ContainsKey('suggestions') -and $Lockfile.suggestions.ContainsKey('cursor')) { $Lockfile.suggestions.cursor } else { @{} }
    foreach ($entry in $cursorSec.GetEnumerator()) {
      $ext = $entry.Key; $pin = $entry.Value
      $inst = $null
      foreach ($line in $installedList) {
        if ($line -match "^$([regex]::Escape($ext))@(.+)") { $inst = $Matches[1]; break }
      }
      if ($null -eq $inst) { & $WarnFn "suggestions.cursor.$ext`: expected $pin, not installed (warn-only)" }
      elseif ($inst -ne $pin) { & $WarnFn "suggestions.cursor.$ext`: expected $pin, installed $inst (warn-only)" }
    }
  } else { & $InfoFn "cursor: no cursor CLI; skipping suggestions.cursor verify" }

  # --- suggestions: always warn (non-authoritative) ---
  if ($Lockfile.ContainsKey('suggestions')) {
    foreach ($sub in $Lockfile.suggestions.Keys) {
      & $WarnFn "suggestions.$sub`: non-authoritative suggestion — not enforced (warn-only per invariant)"
    }
  }

  return $errors
}
