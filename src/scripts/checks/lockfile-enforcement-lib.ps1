#Requires -Version 7.4
# Shared lockfile enforcement probes for both the check step and
# bump-lockfile.ps1 -VerifyInstalled.  Does NOT depend on check-lib.ps1
# (no skip mechanism / Get-StepNumber), so it is safe to source from bump-lockfile.
#
# Message output is delegated via scriptblock parameters so the same probe
# logic serves both the check step (Write-Message / Write-WarningMessage /
# Write-ErrorMessage) and bump-lockfile.ps1 (Write-NucleusInfo / etc.).
#
# WHY: ManagedPaths.ps1 supplies Get-NucleusUserRoot, so the USER-root paths
# below come from the canonical declaration instead of a literal.
$script:NucleusRepoRoot = (Resolve-Path (Join-Path -Path $PSScriptRoot -ChildPath '..\..\..')).Path
. (Join-Path -Path $script:NucleusRepoRoot -ChildPath 'src\platforms\Windows\modules\ManagedPaths.ps1')
# Get-NucleusHostKey scopes the probes to this host; Resolve-NucleusFlakePin
# resolves the revision behind a "flake:<node>" pin.
. (Join-Path -Path $script:NucleusRepoRoot -ChildPath 'src\platforms\Windows\modules\Get-NucleusHostPlatform.ps1')
. (Join-Path -Path $script:NucleusRepoRoot -ChildPath 'src\platforms\Windows\modules\lib\Resolve-NucleusFlakePin.ps1')
# Get-NucleusSriHash is the repo's only SRI SHA256 and the whisper pin stores SRI,
# so the probe must not re-derive the encoding.
. (Join-Path -Path $script:NucleusRepoRoot -ChildPath 'src\platforms\Windows\modules\lib\PsGalleryPin.ps1')

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

  # Probes cover only the packages this host declares in desired.json, so a pin
  # kept for another host is not reported as drift. A manager absent from the
  # registry keeps lockfile-only behaviour.
  $hostKey = Get-NucleusHostKey
  $desiredNames = @{}
  $desiredEntries = @{}
  $desiredRegistryPath = Join-Path $script:NucleusRepoRoot 'src\modules\packages\desired.json'
  if (Test-Path -LiteralPath $desiredRegistryPath) {
    $registry = Get-Content -LiteralPath $desiredRegistryPath -Raw | ConvertFrom-Json -AsHashtable
    foreach ($managerName in $registry.Keys) {
      $managerEntry = $registry[$managerName]
      # Registry keys such as "$schema" are plain strings, not manager entries.
      if ($managerEntry -isnot [hashtable]) { continue }
      if (-not $managerEntry.ContainsKey($hostKey)) { continue }
      $entries = @($managerEntry[$hostKey])
      $names = [System.Collections.Generic.HashSet[string]]::new()
      foreach ($entry in $entries) { $null = $names.Add([string]$entry.name) }  # check-suppress:suppression_doc: HashSet.Add returns a bool that carries no meaning here
      $desiredNames[$managerName] = $names
      $desiredEntries[$managerName] = $entries
    }
  }

  if (Get-Command bun -ErrorAction SilentlyContinue) {  # check-suppress:suppression_doc: tool may not be installed on this host; the else branch reports the skip
    $globalJson = Join-Path $env:USERPROFILE '.\bun\install\global\package.json'
    if (Test-Path $globalJson) {
      $installed = $null
      try { $installed = Get-Content -Raw -Path $globalJson | ConvertFrom-Json -AsHashtable } catch { $installed = $null }
      $bunSec = if ($Lockfile.ContainsKey('bun')) { $Lockfile.bun } else { @{} }
      foreach ($entry in $bunSec.GetEnumerator()) {
        $pkg = $entry.Key; $pin = $entry.Value
        if ($desiredNames.ContainsKey('bun') -and -not $desiredNames['bun'].Contains($pkg)) { continue }
        if ($pin -is [hashtable]) { & $InfoFn "bun.$pkg`: VCS-pinned (rev) — not version-verifiable, skipping"; continue }
        $inst = if ($installed -and $installed.ContainsKey('dependencies') -and $installed.dependencies.ContainsKey($pkg)) { $installed.dependencies[$pkg] } else { $null }
        if ($null -eq $inst) { & $ErrorFn "bun.$pkg`: expected $pin, not installed"; $errors++ }
        elseif ($inst -ne $pin) { & $ErrorFn "bun.$pkg`: expected $pin, installed $inst"; $errors++ }
      }
    } else { & $InfoFn "bun: no global package.json; skipping" }
  } else { & $InfoFn "bun: not installed; skipping enforcement" }

  if (Get-Command uv -ErrorAction SilentlyContinue) {  # check-suppress:suppression_doc: tool may not be installed on this host; the else branch reports the skip
    $uvList = & uv tool list 2>$null  # check-suppress:suppression_doc: list command may emit noise/errors when the tool store is uninitialised; empty output is treated as no-installs and drift is still reported below
    $uvSec = if ($Lockfile.ContainsKey('uv')) { $Lockfile.uv } else { @{} }
    foreach ($entry in $uvSec.GetEnumerator()) {
      $tool = $entry.Key; $pin = $entry.Value
      if ($desiredNames.ContainsKey('uv') -and -not $desiredNames['uv'].Contains($tool)) { continue }
      if ($pin -is [hashtable]) { & $InfoFn "uv.$tool`: VCS-pinned (rev) — not version-verifiable, skipping"; continue }
      $inst = $null
      foreach ($line in $uvList) {
        if ($line -match "^$([regex]::Escape($tool))\s+v?(\d[\w.\-]*)") { $inst = $Matches[1]; break }
      }
      if ($null -eq $inst) { & $ErrorFn "uv.$tool`: expected $pin, not installed"; $errors++ }
      elseif ($inst -ne $pin) { & $ErrorFn "uv.$tool`: expected $pin, installed $inst"; $errors++ }
    }
  } else { & $InfoFn "uv: not installed; skipping enforcement" }

  # A flake-pinned tool has no lockfile version, so the probe compares uv's
  # PEP 610 commit_id against the revision the flake node resolves to.
  if (Get-Command uv -ErrorAction SilentlyContinue) {  # check-suppress:suppression_doc: tool may not be installed on this host; the else branch reports the skip
    foreach ($entry in @($desiredEntries['uv'])) {
      # WHY: the registry is parsed with -AsHashtable, so the pin is a key on a
      # hashtable rather than a property: PSObject.Properties does not list it and
      # every flake-pinned entry would be skipped without a word. A StrictMode read
      # of a missing key is why the presence check comes first.
      $pin = if ($entry.ContainsKey('pin')) { $entry['pin'] } else { $null }
      if (-not $pin) { continue }
      if ($pin -notmatch '^flake:(.+)$') {
        & $ErrorFn "uv.$($entry.name)`: unsupported pin '$pin'; expected 'flake:<node>'"; $errors++
        continue
      }
      $nodeName = $Matches[1]
      $resolvedPin = Resolve-NucleusFlakePin -Node $nodeName -FlakeLockPath (Join-Path $script:NucleusRepoRoot 'src\flake.lock')
      if (-not $resolvedPin.Ok) {
        & $ErrorFn "uv.$($entry.name)`: cannot resolve flake node '$nodeName' ($($resolvedPin.Reason))"; $errors++
        continue
      }
      $toolRoot = if ($env:UV_TOOL_DIR) { Join-Path $env:UV_TOOL_DIR $entry.name } else { Join-Path $env:LOCALAPPDATA "uv\tools\$($entry.name)" }
      # check-suppress:suppression_doc: tool may not be installed; probe is best-effort
      $record = Get-ChildItem -Path $toolRoot -Filter 'direct_url.json' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
      if (-not $record) {
        & $ErrorFn "uv.$($entry.name)`: expected revision $($resolvedPin.Rev), no install record under $toolRoot"; $errors++
        continue
      }
      $direct = Get-Content -LiteralPath $record.FullName -Raw | ConvertFrom-Json -AsHashtable
      $commit = if ($direct.ContainsKey('vcs_info')) { $direct.vcs_info.commit_id } else { $null }
      if (-not $commit) { & $ErrorFn "uv.$($entry.name)`: expected revision $($resolvedPin.Rev), install record has no vcs_info"; $errors++ }
      elseif ($commit -ne $resolvedPin.Rev) { & $ErrorFn "uv.$($entry.name)`: expected revision $($resolvedPin.Rev), installed $commit"; $errors++ }
    }
  } else { & $InfoFn "uv: not installed; skipping flake-pinned revision enforcement" }

  if (Get-Command cargo -ErrorAction SilentlyContinue) {  # check-suppress:suppression_doc: tool may not be installed on this host; the else branch reports the skip
    $cargoList = & cargo install --list 2>$null  # check-suppress:suppression_doc: list command may emit noise/errors when the tool store is uninitialised; empty output is treated as no-installs and drift is still reported below
    $cbSec = if ($Lockfile.ContainsKey('cargo-binstall')) { $Lockfile.'cargo-binstall' } else { @{} }
    foreach ($entry in $cbSec.GetEnumerator()) {
      $crate = $entry.Key; $pin = $entry.Value
      if ($desiredNames.ContainsKey('cargo-binstall') -and -not $desiredNames['cargo-binstall'].Contains($crate)) { continue }
      if ($pin -is [hashtable]) { & $InfoFn "cargo-binstall.$crate`: VCS-pinned (rev) — not version-verifiable, skipping"; continue }
      $inst = $null
      foreach ($line in $cargoList) {
        if ($line -match "^$([regex]::Escape($crate)) v(\d[\w.\-]*)") { $inst = $Matches[1]; break }
      }
      if ($null -eq $inst) { & $ErrorFn "cargo-binstall.$crate`: expected $pin, not installed"; $errors++ }
      elseif ($inst -ne $pin) { & $ErrorFn "cargo-binstall.$crate`: expected $pin, installed $inst"; $errors++ }
    }
  } else { & $InfoFn "cargo: not installed; skipping enforcement" }

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

  # A pin is a version string or a {version, hash} object; only the version is
  # enforceable, because an install is an extracted directory, not the nupkg.
  if (Get-Command pwsh -ErrorAction SilentlyContinue) {  # check-suppress:suppression_doc: tool may not be installed on this host; the else branch reports the skip
    $psGallerySec = if ($Lockfile.ContainsKey('psgallery')) { $Lockfile.psgallery } else { @{} }
    foreach ($entry in $psGallerySec.GetEnumerator()) {
      $mod = $entry.Key; $pin = $entry.Value
      $version = if ($pin -is [hashtable]) { $pin.version } else { $pin }
      $inst = & pwsh -NoProfile -NonInteractive -Command "(Get-Module -ListAvailable -Name '$mod' | Select-Object -First 1).Version.ToString()" 2>$null  # check-suppress:suppression_doc: list command may emit noise/errors when the tool store is uninitialised; empty output is treated as no-installs and drift is still reported below
      if ([string]::IsNullOrWhiteSpace($inst)) { & $ErrorFn "psgallery.$mod`: expected $version, not installed"; $errors++ }
      elseif ($inst.Trim() -ne $version) { & $ErrorFn "psgallery.$mod`: expected $version, installed $($inst.Trim())"; $errors++ }
    }
  } else { & $InfoFn "psgallery: not installed; skipping enforcement" }

  if (Get-Command scoop -ErrorAction SilentlyContinue) {  # check-suppress:suppression_doc: tool may not be installed on this host; the else branch reports the skip
    $scoopList = & scoop list 2>$null  # check-suppress:suppression_doc: list command may emit noise/errors when the tool store is uninitialised; empty output is treated as no-installs and drift is still reported below
    $scoopSec = if ($Lockfile.ContainsKey('scoop')) { $Lockfile.scoop } else { @{} }
    foreach ($entry in $scoopSec.GetEnumerator()) {
      $app = $entry.Key; $pin = $entry.Value
      if ($desiredNames.ContainsKey('scoop') -and -not $desiredNames['scoop'].Contains($app)) { continue }
      if ($pin -is [hashtable]) { & $InfoFn "scoop.$app`: VCS-pinned (rev) — not version-verifiable, skipping"; continue }
      $inst = $null
      foreach ($line in $scoopList) {
        if ($line -match "^$([regex]::Escape($app))\s+(\d[\w.\-]*)") { $inst = $Matches[1]; break }
      }
      if ($null -eq $inst) { & $ErrorFn "scoop.$app`: expected $pin, not installed"; $errors++ }
      elseif ($inst -ne $pin) { & $ErrorFn "scoop.$app`: expected $pin, installed $inst"; $errors++ }
    }
  } else { & $InfoFn "scoop: not installed; skipping enforcement" }

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

  # source-builds: VCS/rev pins are not version-verifiable
  if ($Lockfile.ContainsKey('source-builds')) {
    & $InfoFn "source-builds: VCS/rev-pinned — not version-verifiable, skipping enforcement"
  }

  # Sync-Superpowers.ps1 checks the plugin out at the pinned revision, so the
  # probe verifies the checkout; the POSIX symlink into /nix/store is not
  # observable from Windows.
  $expectedRev = $null
  if ($Lockfile.ContainsKey('cursor') -and $Lockfile.cursor.ContainsKey('superpowers')) {
    $expectedRev = $Lockfile.cursor.superpowers.rev
  }
  if ($expectedRev) {
    $pluginDir = Join-Path (Get-NucleusUserRoot) 'plugins\superpowers'
    if (-not (Test-Path -LiteralPath $pluginDir)) {
      & $ErrorFn "superpowers.$expectedRev`: plugin checkout not found at $pluginDir"; $errors++
    }
    elseif (-not (Test-Path -LiteralPath (Join-Path -Path $pluginDir -ChildPath '.git'))) {
      & $ErrorFn "superpowers.$expectedRev`: $pluginDir is not a managed git checkout"; $errors++
    }
    else {
      # check-suppress:suppression_doc: probe -- git may be absent from PATH; the $null check below reports that as an error.
      $git = Get-Command -Name git -ErrorAction SilentlyContinue
      if ($null -eq $git) {
        & $ErrorFn "superpowers.$expectedRev`: git not found; cannot verify the checkout revision"; $errors++
      }
      else {
        # WHY: the whole output is captured before its first line is taken. Piping the
        # native command into `Select-Object -First 1` stops it after one line and
        # left $LASTEXITCODE holding another command's status, which made a valid
        # checkout look broken. stderr goes to its own file so the revision on
        # stdout is unambiguous.
        $headStderrFile = [System.IO.Path]::GetTempFileName()
        try {
          $headLines = @(& $git.Source -C $pluginDir rev-parse HEAD 2>$headStderrFile)
          $headExit = $LASTEXITCODE
          $headStderr = [System.IO.File]::ReadAllText($headStderrFile).Trim()
        }
        finally {
          Remove-Item -LiteralPath $headStderrFile -Force
        }
        $head = if ($headLines.Count -gt 0) { [string]$headLines[0] } else { '' }
        if ($headExit -ne 0 -or [string]::IsNullOrWhiteSpace($head)) {
          & $ErrorFn "superpowers.$expectedRev`: git rev-parse failed in $pluginDir (exit $headExit): $headStderr"; $errors++
        }
        elseif ($head.Trim() -ne $expectedRev) {
          & $ErrorFn "superpowers.$expectedRev`: checkout is at $($head.Trim())"; $errors++
        }
        else {
          & $InfoFn "superpowers.$expectedRev`: checkout present at $pluginDir"
        }
      }
    }
  }

  # No package manager ships the whisper weights, so every version probe above is
  # blind to a drifted model; the probe re-hashes the deployed file against the
  # lockfile SRI instead.
  if ($Lockfile.ContainsKey('whisper')) {
    $modelDir = Join-Path (Get-NucleusUserRoot) 'models'
    foreach ($modelName in @($Lockfile.whisper.Keys)) {
      $pin = $Lockfile.whisper.$modelName
      $expectedSri = $pin.hash
      if ([string]::IsNullOrWhiteSpace($expectedSri)) {
        & $ErrorFn "whisper.$modelName`: lockfile entry has no hash"; $errors++
        continue
      }
      $modelPath = Join-Path -Path $modelDir -ChildPath $modelName
      if (-not (Test-Path -LiteralPath $modelPath -PathType Leaf)) {
        & $ErrorFn "whisper.$modelName`: not deployed at $modelPath"; $errors++
        continue
      }
      $actualSri = Get-NucleusSriHash -Path $modelPath
      if ($actualSri -ne $expectedSri) {
        & $ErrorFn "whisper.$modelName`: expected $expectedSri, found $actualSri"; $errors++
      }
      else {
        & $InfoFn "whisper.$modelName`: present ($expectedSri)"
      }
    }
  }

  # suggestions.opencode: git+URL pins have no installed-version query, so each
  # entry is reported at info level and never errors.
  if ($Lockfile.ContainsKey('suggestions') -and $Lockfile.suggestions.ContainsKey('opencode')) {
    foreach ($entry in $Lockfile.suggestions.opencode.Keys) {
      & $InfoFn "suggestions.opencode.$entry`: VCS-pinned — not version-verifiable, skipping"
    }
  }

  # suggestions.vscode: warn-only per the suggestions invariant, and not locked on
  # POSIX, where flake.lock owns the extension list.
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

  # suggestions.cursor: warn-only per the suggestions invariant; no cursor CLI is a
  # clean skip.
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

  # suggestions: always warn, since the section is non-authoritative
  if ($Lockfile.ContainsKey('suggestions')) {
    foreach ($sub in $Lockfile.suggestions.Keys) {
      & $WarnFn "suggestions.$sub`: non-authoritative suggestion — not enforced (warn-only per invariant)"
    }
  }

  return $errors
}
