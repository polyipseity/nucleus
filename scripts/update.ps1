<#
.SYNOPSIS
  Runs the consolidated Windows update workflow.

.DESCRIPTION
  Executes the native Windows update sequence in one command. The -Action
  parameter selects the scope:
    all      (default) flake input updates + SOPS rewrap + lockfile bump
    lockfile           only the lockfile-bumping step

  The lockfile-bumping logic was folded in from the deleted
  scripts/bump-lockfile.ps1 (the nucleus command surface merged
  `bump-lockfile` into `nucleus-update lockfile`).

  Uses the NUCLEUS_REPO_ROOT environment variable to locate the repository
  root; falls back to the parent of the script directory.

.PARAMETER Action
  Scope to run: 'all' (default) or 'lockfile'.

.PARAMETER NoFlake
  Do not run nix flake update (default: $false). Only applies to -Action all.

.PARAMETER NoSops
  Do not run sops updatekeys (default: $false). Only applies to -Action all.

.PARAMETER Sections
  Comma-separated section names to update (default: all). Only applies to
  -Action lockfile. Legacy bare tokens (nixos-iso, tart-images) and the cargo
  alias normalize to their canonical dotted form; unknown tokens are rejected.

.PARAMETER Verify
  Check for updates without writing; exit 1 if changes would be made. Only
  applies to -Action lockfile.

.PARAMETER VerifyInstalled
  Verify installed tool versions against the pinned lockfile sections; exit 1
  on drift. Never writes. Only applies to -Action lockfile.

.PARAMETER ListSections
  Print valid section names, one per line, and exit 0. Only applies to
  -Action lockfile.

.EXAMPLE
  .\update.ps1

.EXAMPLE
  .\update.ps1 -Action lockfile

.EXAMPLE
  .\update.ps1 -NoFlake -NoSops

.NOTES
  Environment variables: NUCLEUS_NO_FLAKE, NUCLEUS_NO_SOPS, NUCLEUS_REPO_ROOT.
  Exit codes: 0 on success; non-zero on failure.
#>
[CmdletBinding()]
param(
  [ValidateSet('all', 'lockfile')]
  [string]$Action = 'all',
  [switch]$NoFlake = $(if ($env:NUCLEUS_NO_FLAKE -eq 'true') { $true } else { $false }),
  [switch]$NoSops = $(if ($env:NUCLEUS_NO_SOPS -eq 'true') { $true } else { $false }),
  [Alias("h")]
  [switch]$Help,
  [string]$Sections = '',
  [switch]$Verify,
  [switch]$VerifyInstalled,
  [switch]$ListSections
)

$ErrorActionPreference = 'Stop'

$modulePath = Join-Path $PSScriptRoot '..\src\platforms\Windows\modules\Format-NucleusOutput.psm1'
Import-Module $modulePath -Force -DisableNameChecking

if ($Help) {
  Get-Help $PSCommandPath -Detailed
  return
}

$repoRoot = if ($env:NUCLEUS_REPO_ROOT) { $env:NUCLEUS_REPO_ROOT } else { (Resolve-Path -Path (Join-Path -Path $PSScriptRoot -ChildPath '..')).Path }

# ---------------------------------------------------------------------------
# Invoke-UpdateAll — flake input updates + SOPS recipient rewrap
# ---------------------------------------------------------------------------
function Invoke-UpdateAll {
  # check-suppress:suppression_doc: probe whether tool is installed; Get-Command throws when absent.
  if (-not $NoFlake -and (Get-Command -Name 'nix.exe' -ErrorAction SilentlyContinue)) {
    $flakeOutput = & nix.exe --option warn-dirty false flake update --flake (Join-Path -Path $repoRoot -ChildPath 'src') 2>&1
    if ($LASTEXITCODE -ne 0) {
      $joined = ($flakeOutput | Out-String)
      if ($joined -match 'API rate limit exceeded|unable to download|HTTP error 403') {
        Write-NucleusWarning 'flake update skipped due to transient fetch/rate-limit error.'
      }
      else {
        throw 'nucleus: nix flake update failed.'
      }
    }
  }

  # check-suppress:suppression_doc: probe whether tool is installed; Get-Command throws when absent.
  if (-not $NoSops -and -not (Get-Command -Name 'sops.exe' -ErrorAction SilentlyContinue)) {
    throw 'nucleus: sops.exe is required for update secret rewrap step.'
  }

  $sopsConfig = Join-Path -Path $repoRoot -ChildPath '.sops.yaml'

  if (-not $NoSops) {
    $usersSecretsDir = Join-Path -Path $repoRoot -ChildPath 'src\secrets\users'
    if (Test-Path -Path $usersSecretsDir) {
      Get-ChildItem -Path $usersSecretsDir -Filter '*.yml' -File | ForEach-Object {
        & sops --config $sopsConfig updatekeys --yes $_.FullName
        if ($LASTEXITCODE -ne 0) {
          throw "nucleus: failed to rewrap per-user secret file '$($_.FullName)'."
        }
      }
    }
    # check-suppress:suppression_doc: probe -- no encrypted wallpaper blobs may exist; empty result handled.
    $wallpaperList = @(Get-ChildItem -Path (Join-Path -Path $repoRoot -ChildPath 'src\users') -Recurse -Filter '*.sops' -File -ErrorAction SilentlyContinue |
      Where-Object { $_.FullName -match '[\\/]wallpapers[\\/]encrypted[\\/]' })
    foreach ($encryptedWallpaper in $wallpaperList) {
      & sops --config $sopsConfig updatekeys --yes $encryptedWallpaper.FullName
      if ($LASTEXITCODE -ne 0) {
        throw "nucleus: failed to rewrap wallpaper blob '$($encryptedWallpaper.FullName)'."
      }
    }
  }
}

# ---------------------------------------------------------------------------
# Invoke-LockfileBump — query each available tool for the current version of
# each pinned item and write an updated lockfile atomically. Inlined from the
# deleted scripts/bump-lockfile.ps1 (folded into `nucleus-update lockfile`).
# ---------------------------------------------------------------------------
function Invoke-LockfileBump {
  # --list-sections: print the canonical section names and exit 0 (no lockfile
  # read required, matching the bash twin's early-exit behavior).
  if ($ListSections) {
    $validSectionsCsv = 'bun,cargo,cargo-binstall,pwsh,rustup,scoop,source-builds,uv,version,vm-setup,vm-setup.nixos-iso,vm-setup.tart-images,winget,suggestions.homebrew,suggestions.homebrew.masApps,suggestions.ollama,suggestions.vscode,suggestions.vm-setup.windows'
    foreach ($s in ($validSectionsCsv -split ',')) {
      Write-NucleusInfo $s
    }
    return
  }

  $lockfileRel = 'src/lockfiles/lockfile.json'
  $lockfileAbs = Join-Path -Path $repoRoot -ChildPath $lockfileRel

  if (-not (Test-Path -Path $lockfileAbs)) {
    Write-NucleusError -CommandName update -Message "lockfile not found at $lockfileAbs" -ErrorAction Continue
    exit 1
  }

  # All sections run when no explicit selection is supplied. Parse and normalize
  # the --sections token list exactly like the bash twin: trim whitespace per
  # token, map legacy bare sub-section names and the cargo alias to canonical
  # dotted form, and reject anything unknown.
  $validSectionsCsv = 'bun,cargo,cargo-binstall,pwsh,rustup,scoop,source-builds,uv,version,vm-setup,vm-setup.nixos-iso,vm-setup.tart-images,winget,suggestions.homebrew,suggestions.homebrew.masApps,suggestions.ollama,suggestions.vscode,suggestions.vm-setup.windows'
  $sectionTokens = @()
  if (-not [string]::IsNullOrEmpty($Sections)) {
    foreach ($tok in ($Sections -split ',')) {
      $tok = $tok.Trim()
      if ([string]::IsNullOrEmpty($tok)) { continue }
      switch ($tok) {
        'nixos-iso' { $tok = 'vm-setup.nixos-iso' }
        'tart-images' { $tok = 'vm-setup.tart-images' }
        'cargo' { $tok = 'cargo-binstall' }
      }
      if (",$validSectionsCsv," -notmatch ",$tok,") {
        Write-NucleusError -CommandName update -Message "unknown section '$tok' (valid: $validSectionsCsv)" -ErrorAction Continue
        exit 1
      }
      $sectionTokens += $tok
    }
  }

  # Explicitly-selected sections without an updater are kept manual; warn so the
  # run does not silently skip them (mirrors the bash twin's no-updater warning).
  foreach ($tok in $sectionTokens) {
    if (",source-builds,suggestions.homebrew.masApps,suggestions.vm-setup.windows,version," -match ",$tok,") {
      Write-NucleusWarning "section '$tok' has no updater — kept manual"
    }
  }

  function Write-Update {
    param([string]$Section, [string]$Key, [string]$OldValue, [string]$NewValue)
    # Change tracker: every mutation flows through this function, so the flag
    # decides whether the write path stamps 'updated' and rewrites the file.
    # $script: scope is required — functions run in a child scope and a plain
    # assignment would only update the function-local copy.
    $script:changed = $true
    Write-NucleusInfo "updating ${Section}.${Key} from ${OldValue} to ${NewValue}"
  }

  function Test-SectionEnabled {
    param([string]$Name)
    if ([string]::IsNullOrEmpty($Sections)) { return $true }
    foreach ($token in $sectionTokens) {
      if ($Name -eq $token -or $Name.StartsWith("$token.")) { return $true }
    }
    return $false
  }

  function Test-SuggestionsEnabled {
    param([string]$Name)
    # Suggestions sections are warn-only audit data, never authoritative pins.
    # They are selected only by an explicit suggestions.* token (or the default
    # all-sections run). A parent token (suggestions, suggestions.homebrew) also
    # selects all of its dotted children.
    if ([string]::IsNullOrEmpty($Sections)) { return $true }
    foreach ($token in $sectionTokens) {
      if ($token.StartsWith('suggestions') -and ($Name -eq $token -or $Name.StartsWith("$token."))) { return $true }
    }
    return $false
  }

  function ConvertTo-Hashtable {
    param([object]$InputObject)
    if ($InputObject -is [System.Management.Automation.PSCustomObject]) {
      $ht = @{}
      $InputObject.PSObject.Properties | ForEach-Object {
        $ht[$_.Name] = ConvertTo-Hashtable $_.Value
      }
      return $ht
    } elseif ($InputObject -is [object[]]) {
      $list = @()
      foreach ($item in $InputObject) {
        $list += ConvertTo-Hashtable $item
      }
      return ,$list  # comma preserves array
    } else {
      return $InputObject
    }
  }

  $rawJson = Get-Content -Path $lockfileAbs -Raw -Encoding UTF8
  $lockfile = $rawJson | ConvertFrom-Json -Depth 32
  $ht = ConvertTo-Hashtable $lockfile

  # --verify-installed: verify installed tool versions against the pinned
  # lockfile sections and exit (never writes). Delegates to the shared probe
  # library used by the check step so behavior stays identical.
  if ($VerifyInstalled) {
    . (Join-Path $repoRoot 'src/scripts/checks/lockfile-enforcement-lib.ps1')
    $drift = Invoke-LockfileEnforcement `
      -Lockfile $ht `
      -InfoFn { param($m) Write-NucleusInfo $m } `
      -WarnFn { param($m) Write-NucleusWarning $m } `
      -ErrorFn { param($m) Write-NucleusError -CommandName update -Message $m -ErrorAction Continue }
    exit $drift
  }

  # Change tracking: the timestamp is stamped and the file written only when at
  # least one section produced a change (set by Write-Update). Stamping before
  # the queries would make every run rewrite the file (timestamp churn).
  $changed = $false

  # -------------------------------------------------------------------------
  # winget — winget show --id <id>
  # -------------------------------------------------------------------------
  if (Test-SectionEnabled 'winget') {
    if (Get-Command -Name 'winget' -ErrorAction SilentlyContinue) {  # check-suppress:suppression_doc: probe -- tool may not be installed on this platform; the else branch warns and skips the section
      if ($ht.ContainsKey('winget') -and $ht['winget'] -is [hashtable]) {
        # Snapshot the keys: assigning a value below invalidates the live
        # KeyCollection enumerator on .NET Core ('Collection was modified').
        foreach ($key in @($ht['winget'].Keys)) {
          $old = $ht['winget'][$key]
          # check-suppress:suppression_doc: probe -- package may not exist; stderr suppressed for clean output.
          $result = & winget show --id $key 2>$null | Select-String -Pattern '^Version '
          if ($result) {
            $new = ($result -split ':\s*', 2)[-1].Trim()
            if (-not [string]::IsNullOrEmpty($new) -and $new -ne $old) {
              Write-Update -Section 'winget' -Key $key -OldValue $old -NewValue $new
              $ht['winget'][$key] = $new
            }
          }
        }
      }
    } else {
      Write-NucleusWarning 'winget not found — skipping winget section'
    }
  }

  # -------------------------------------------------------------------------
  # scoop — scoop info <pkg>
  # -------------------------------------------------------------------------
  if (Test-SectionEnabled 'scoop') {
    if (Get-Command -Name 'scoop' -ErrorAction SilentlyContinue) {  # check-suppress:suppression_doc: probe -- tool may not be installed on this platform; the else branch warns and skips the section
      if ($ht.ContainsKey('scoop') -and $ht['scoop'] -is [hashtable]) {
        foreach ($key in @($ht['scoop'].Keys)) {
          $old = $ht['scoop'][$key]
          # check-suppress:suppression_doc: probe -- package may not exist; stderr suppressed for clean output.
          $result = & scoop info $key 2>$null | Select-String -Pattern '^Version '
          if ($result) {
            $new = ($result -split ':\s*', 2)[-1].Trim()
            if (-not [string]::IsNullOrEmpty($new) -and $new -ne $old) {
              Write-Update -Section 'scoop' -Key $key -OldValue $old -NewValue $new
              $ht['scoop'][$key] = $new
            }
          }
        }
      }
    } else {
      Write-NucleusWarning 'scoop not found — skipping scoop section'
    }
  }

  # -------------------------------------------------------------------------
  # cargo-binstall — crates.io API
  # -------------------------------------------------------------------------
  if (Test-SectionEnabled 'cargo-binstall') {
    if ($ht.ContainsKey('cargo-binstall') -and $ht['cargo-binstall'] -is [hashtable]) {
      foreach ($key in @($ht['cargo-binstall'].Keys)) {
        if ($ht['cargo-binstall'][$key] -is [hashtable]) {
          continue  # object entry — no version query applies
        }
        $old = $ht['cargo-binstall'][$key]
        $new = $null
        try {
          # check-suppress:suppression_doc: probe -- crate may not exist or network unavailable; cargo search is the fallback below
          $resp = Invoke-RestMethod -Uri "https://crates.io/api/v1/crates/$key" -Headers @{ 'User-Agent' = 'nucleus-bump-lockfile' }
          if ($resp.crate.max_stable_version) {
            $new = $resp.crate.max_stable_version
          } elseif ($resp.versions -and $resp.versions.Count -gt 0) {
            $new = $resp.versions[0].num
          }
        } catch {
          $new = $null  # check-suppress:suppression_doc: API failure — cargo search below is the only other version source
        }
        if ([string]::IsNullOrEmpty($new)) {
          # check-suppress:suppression_doc: probe -- crate may not exist; stderr suppressed for clean output.
          $searchOutput = & cargo search --limit 1 $key 2>$null
          if ($searchOutput) {
            foreach ($line in $searchOutput) {
              $match = [regex]::Match($line.Trim(), '^[^\s=]+\s*=\s*"([^"]+)"')
              if ($match.Success) {
                $new = $match.Groups[1].Value.Trim()
                break
              }
            }
          }
        }
        if ([string]::IsNullOrEmpty($new)) {
          Write-NucleusWarning "cargo-binstall.${key}: no version source (crates.io API and cargo search both failed)"
          continue
        }
        if ($new -ne $old) {
          Write-Update -Section 'cargo-binstall' -Key $key -OldValue $old -NewValue $new
          $ht['cargo-binstall'][$key] = $new
        }
      }
    }
  }

  # -------------------------------------------------------------------------
  # bun — npm registry API (curl)
  # -------------------------------------------------------------------------
  if (Test-SectionEnabled 'bun') {
    if (Get-Command -Name 'curl' -ErrorAction SilentlyContinue) {  # check-suppress:suppression_doc: probe -- tool may not be installed on this platform; the else branch warns and skips the section
      if ($ht.ContainsKey('bun') -and $ht['bun'] -is [hashtable]) {
        foreach ($key in @($ht['bun'].Keys)) {
          $old = $ht['bun'][$key]
          # check-suppress:suppression_doc: probe -- package may not exist; stderr suppressed for clean output.
          $result = & curl -fsSL "https://registry.npmjs.org/$key/latest" 2>$null
          if ($result) {
            $parsed = $result | ConvertFrom-Json
            $new = $parsed.version.Trim()
            if (-not [string]::IsNullOrEmpty($new) -and $new -ne $old) {
              Write-Update -Section 'bun' -Key $key -OldValue $old -NewValue $new
              $ht['bun'][$key] = $new
            }
          }
        }
      }
    } else {
      Write-NucleusWarning 'curl: command not found — skipping bun section'
    }
  }

  # -------------------------------------------------------------------------
  # uv — uv tool list
  # -------------------------------------------------------------------------
  if (Test-SectionEnabled 'uv') {
    if (Get-Command -Name 'uv' -ErrorAction SilentlyContinue) {  # check-suppress:suppression_doc: probe -- tool may not be installed on this platform; the else branch warns and skips the section
      # check-suppress:suppression_doc: probe -- uv may not be installed; stderr suppressed for clean output.
      $uvOutput = & uv tool list 2>$null
      if ($uvOutput) {
        # Build hashtable from uv tool list output.
        # Format: "package@version" or "package v1.0.0" or "- package@version"
        $uvInstalled = @{}
        foreach ($line in $uvOutput) {
          $line = $line.Trim()
          if ([string]::IsNullOrEmpty($line)) { continue }
          # Strip leading dashes/bullets
          $line = $line -replace '^-\s+', ''
          if ($line -match '@') {
            $parts = $line -split '@', 2
            $pkg = $parts[0].Trim()
            $ver = $parts[1].Trim()
          } else {
            # "package v1.0.0"
            $parts = $line -split '\s+', 2
            $pkg = $parts[0].Trim()
            $ver = if ($parts.Count -gt 1) { $parts[1].Trim() } else { '' }
          }
          $ver = $ver -replace '^v', ''
          if (-not [string]::IsNullOrEmpty($pkg) -and -not [string]::IsNullOrEmpty($ver)) {
            $uvInstalled[$pkg] = $ver
          }
        }

        if ($ht.ContainsKey('uv') -and $ht['uv'] -is [hashtable]) {
          foreach ($key in @($ht['uv'].Keys)) {
            if ($ht['uv'][$key] -is [hashtable]) {
              continue  # VCS hash-pin entry — no CLI query can update the rev
            }
            $old = $ht['uv'][$key]
            if ($uvInstalled.ContainsKey($key)) {
              $new = $uvInstalled[$key]
              if (-not [string]::IsNullOrEmpty($new) -and $new -ne $old) {
                Write-Update -Section 'uv' -Key $key -OldValue $old -NewValue $new
                $ht['uv'][$key] = $new
              }
            }
          }
        }
      }
    } else {
      Write-NucleusWarning 'uv not found — skipping uv section'
    }
  }

  # -------------------------------------------------------------------------
  # rustup — rustc +<channel> --version
  # -------------------------------------------------------------------------
  if (Test-SectionEnabled 'rustup') {
    if (Get-Command -Name 'rustup' -ErrorAction SilentlyContinue) {  # check-suppress:suppression_doc: probe -- tool may not be installed on this platform; the else branch warns and skips the section
      # Get installed toolchains
      # check-suppress:suppression_doc: probe -- rustup may not be installed; stderr suppressed for clean output.
      $toolchains = & rustup toolchain list 2>$null
      $toolchainSet = @{}
      if ($toolchains) {
        foreach ($tc in $toolchains) {
          # Line format: "stable-aarch64-pc-windows-msvc (default)"
          # Extract the channel name (everything before first '-')
          $channel = ($tc -split '-', 2)[0].Trim()
          if (-not [string]::IsNullOrEmpty($channel)) {
            $toolchainSet[$channel] = $true
          }
        }
      }

      if ($ht.ContainsKey('rustup') -and $ht['rustup'] -is [hashtable]) {
        foreach ($key in @($ht['rustup'].Keys)) {
          $old = $ht['rustup'][$key]
          if ($toolchainSet.ContainsKey($key)) {
            # check-suppress:suppression_doc: probe -- toolchain may not be installed; stderr suppressed for clean output.
            $versionOutput = & rustc "+$key" --version 2>$null
            if ($versionOutput) {
              # nightly pins carry a valid -YYYY-MM-DD archive suffix; record the
              # full nightly-YYYY-MM-DD spec. stable/beta are rolling channels
              # pinned by version (X.Y.Z) — a date suffix is invalid for them, so
              # record the bare version instead of the release date.
              if ($key -eq 'nightly' -or $key -match '^nightly-\d{4}-\d{2}-\d{2}$') {
                $match = [regex]::Match($versionOutput, 'nightly-\d{4}-\d{2}-\d{2}')
              } else {
                $match = [regex]::Match($versionOutput, '\d+\.\d+\.\d+')
              }
              if ($match.Success) {
                $new = $match.Value
                if (-not [string]::IsNullOrEmpty($new) -and $new -ne $old) {
                  Write-Update -Section 'rustup' -Key $key -OldValue $old -NewValue $new
                  $ht['rustup'][$key] = $new
                }
              }
            }
          }
        }
      }
    } else {
      Write-NucleusWarning 'rustup not found — skipping rustup section'
    }
  }

  # -------------------------------------------------------------------------
  # pwsh — Find-Module via pwsh -NoProfile
  # -------------------------------------------------------------------------
  if (Test-SectionEnabled 'pwsh') {
    if (Get-Command -Name 'pwsh' -ErrorAction SilentlyContinue) {  # check-suppress:suppression_doc: probe -- tool may not be installed on this platform; the else branch warns and skips the section
      if ($ht.ContainsKey('pwsh') -and $ht['pwsh'] -is [hashtable]) {
        foreach ($key in @($ht['pwsh'].Keys)) {
          $old = $ht['pwsh'][$key]
          # check-suppress:suppression_doc: probe -- module may not exist in PSGallery; stderr suppressed for clean output.
          $result = & pwsh -NoProfile -Command "Find-Module -Name '$key' | Select-Object -ExpandProperty Version" 2>$null
          if ($result) {
            $new = $result.Trim()
            if (-not [string]::IsNullOrEmpty($new) -and $new -ne $old) {
              Write-Update -Section 'pwsh' -Key $key -OldValue $old -NewValue $new
              $ht['pwsh'][$key] = $new
            }
          }
        }
      }
    } else {
      Write-NucleusWarning 'pwsh not found — skipping pwsh section'
    }
  }

  # -------------------------------------------------------------------------
  # suggestions.vscode — code / code-insiders --list-extensions --show-versions
  # Warn-only audit data (Windows installs --pre-release --force; POSIX uses flake.lock).
  # -------------------------------------------------------------------------
  if (Test-SuggestionsEnabled 'suggestions.vscode') {
    $vscodeOutput = $null
    # check-suppress:suppression_doc: probe whether tool is installed; Get-Command throws when absent.
    if (Get-Command -Name 'code' -ErrorAction SilentlyContinue) {
      # check-suppress:suppression_doc: probe -- tool may not be installed; stderr suppressed for clean output.
      $vscodeOutput = & code --list-extensions --show-versions 2>$null
    # check-suppress:suppression_doc: probe whether tool is installed; Get-Command throws when absent.
    } elseif (Get-Command -Name 'code-insiders' -ErrorAction SilentlyContinue) {
      # check-suppress:suppression_doc: probe -- tool may not be installed; stderr suppressed for clean output.
      $vscodeOutput = & code-insiders --list-extensions --show-versions 2>$null
    } else {
      Write-NucleusWarning 'code/code-insiders not found — skipping suggestions.vscode section'
    }

    if ($vscodeOutput) {
      # Build extension map from output lines "publisher.extension@version"
      $vscodeExts = @{}
      foreach ($line in $vscodeOutput) {
        $line = $line.Trim()
        if ([string]::IsNullOrEmpty($line)) { continue }
        $atIdx = $line.LastIndexOf('@')
        if ($atIdx -ge 0) {
          $pkg = $line.Substring(0, $atIdx)
          $ver = $line.Substring($atIdx + 1)
          if (-not [string]::IsNullOrEmpty($pkg) -and -not [string]::IsNullOrEmpty($ver)) {
            $vscodeExts[$pkg] = $ver
          }
        }
      }

      if ($ht.ContainsKey('suggestions') -and $ht['suggestions'] -is [hashtable] -and $ht['suggestions'].ContainsKey('vscode') -and $ht['suggestions']['vscode'] -is [hashtable]) {
        foreach ($key in @($ht['suggestions']['vscode'].Keys)) {
          $old = $ht['suggestions']['vscode'][$key]
          if ($vscodeExts.ContainsKey($key)) {
            $new = $vscodeExts[$key]
            if (-not [string]::IsNullOrEmpty($new) -and $new -ne $old) {
              Write-Update -Section 'suggestions.vscode' -Key $key -OldValue $old -NewValue $new
              $ht['suggestions']['vscode'][$key] = $new
            }
          }
        }
      }
    }
  }

  # -------------------------------------------------------------------------
  # suggestions.ollama — ollama show <name>:<tag> --format json
  # Warn-only audit data.
  # -------------------------------------------------------------------------
  if (Test-SuggestionsEnabled 'suggestions.ollama') {
    # Point at the Ollama daemon directly, bypassing the LiteLLM proxy that
    # home.sessionVariables.OLLAMA_HOST (127.0.0.1:4000) normally routes to.
    if (Get-Command -Name 'ollama' -ErrorAction SilentlyContinue) {  # check-suppress:suppression_doc: probe -- tool may not be installed on this platform; the else branch warns and skips the section
      if ($ht.ContainsKey('suggestions') -and $ht['suggestions'] -is [hashtable] -and $ht['suggestions'].ContainsKey('ollama') -and $ht['suggestions']['ollama'] -is [hashtable]) {
        foreach ($hostName in $ht['suggestions']['ollama'].Keys) {
          $models = $ht['suggestions']['ollama'][$hostName]
          if ($models -isnot [System.Collections.IList]) { continue }

          for ($idx = 0; $idx -lt $models.Count; $idx++) {
            $entry = $models[$idx]
            $name = $entry['name']
            $tag = $entry['tag']
            if ([string]::IsNullOrEmpty($name) -or [string]::IsNullOrEmpty($tag)) { continue }

            $hasDigest = $entry.ContainsKey('digest')
            $oldDigest = if ($hasDigest) { $entry['digest'] } else { $null }

            $ollamaHostAddr = if ($env:NUCLEUS_OLLAMA_HOST) { $env:NUCLEUS_OLLAMA_HOST } else { # check-suppress:suppression_doc: probe -- services.json may not exist yet; falls back to default localhost port
            $svc = Get-Content -Raw (Join-Path $repoRoot 'src/modules/services.json') -ErrorAction SilentlyContinue | ConvertFrom-Json; if ($svc.ollama.network.default) { "$($svc.ollama.network.default.host):$($svc.ollama.network.default.port)" } else { '127.0.0.1:11434' } }
            try {
              $oldOllamaHost = $env:OLLAMA_HOST
              $env:OLLAMA_HOST = $ollamaHostAddr
              # check-suppress:suppression_doc: probe -- model may not exist in registry; stderr suppressed for clean output.
              $ollamaInfo = & ollama show "${name}:${tag}" --format json 2>$null
              $env:OLLAMA_HOST = $oldOllamaHost
              if ($ollamaInfo) {
                $ollamaJson = $ollamaInfo | Out-String | ConvertFrom-Json -Depth 10
                $newDigest = $ollamaJson.digest
                if (-not [string]::IsNullOrEmpty($newDigest) -and $newDigest -ne $oldDigest) {
                  Write-Update -Section "ollama ($hostName)" -Key "${name}:${tag}" -OldValue ($oldDigest ?? 'none') -NewValue $newDigest
                  $entry['digest'] = $newDigest
                }
              }
            } catch {
              Write-NucleusWarning "ollama show failed for ${name}:${tag}; keeping existing digest"
            }
          }
        }
      }
    } else {
      Write-NucleusWarning 'ollama not found — skipping ollama section'
    }
  }

  # -------------------------------------------------------------------------
  # vm-setup.nixos-iso — Query NixOS channel for latest ISO URL and SHA-256
  # -------------------------------------------------------------------------
  if (Test-SectionEnabled 'vm-setup.nixos-iso') {
    if ($ht.ContainsKey('vm-setup') -and $ht['vm-setup'].ContainsKey('nixos-iso') -and $ht['vm-setup']['nixos-iso'] -is [hashtable]) {
      foreach ($arch in @($ht['vm-setup']['nixos-iso'].Keys)) {
        $entry = $ht['vm-setup']['nixos-iso'][$arch]
        $oldUrl = $entry['url']
        $oldDigest = $entry['digest']

        $latestUrl = "https://channels.nixos.org/nixos-unstable/latest-nixos-minimal-${arch}.iso"
        try {
          $request = [System.Net.WebRequest]::Create($latestUrl)
          $request.Method = 'HEAD'
          $request.AllowAutoRedirect = $true
          $response = $request.GetResponse()
          $resolvedUrl = $response.ResponseUri.AbsoluteUri
          $response.Close()
        } catch {
          Write-NucleusWarning "could not resolve ${latestUrl} for ${arch}: $($_.Exception.Message)"
          continue
        }

        $sha256Url = "${resolvedUrl}.sha256"
        try {
          $sha256Content = (Invoke-WebRequest -Uri $sha256Url -UseBasicParsing).Content
          if ($sha256Content -match '^([0-9a-f]{64})') {
            $newSha256 = $Matches[1]
          } else {
            Write-NucleusWarning "could not parse checksum from ${sha256Url}"
            continue
          }
        } catch {
          Write-NucleusWarning "could not fetch checksum for ${arch}: $($_.Exception.Message)"
          continue
        }
        $newDigest = "sha256:${newSha256}"

        if ($oldUrl -ne $resolvedUrl -or $oldDigest -ne $newDigest) {
          Write-Update -Section 'vm-setup.nixos-iso' -Key $arch -OldValue ($oldDigest -replace '^sha256:', '') -NewValue "${newSha256:0:12}..."
          $ht['vm-setup']['nixos-iso'][$arch] = @{ url = $resolvedUrl; digest = $newDigest }
        }
      }
    }
  }

  # -------------------------------------------------------------------------
  # vm-setup.tart-images — Query GHCR OCI registry for Cirrus CI macOS base image digests
  # -------------------------------------------------------------------------
  if (Test-SectionEnabled 'vm-setup.tart-images') {
    if ($ht.ContainsKey('vm-setup') -and $ht['vm-setup'].ContainsKey('tart-images') -and $ht['vm-setup']['tart-images'] -is [hashtable]) {
      foreach ($osVersion in $ht['vm-setup']['tart-images'].Keys) {
        $entry = $ht['vm-setup']['tart-images'][$osVersion]
        $oldImage = $entry['image']
        $oldDigest = $entry['digest']
        if ([string]::IsNullOrEmpty($oldImage)) { continue }

        # Extract OCI repo name from image URI
        $imageRepo = $oldImage -replace '^ghcr\.io/', ''
        if ([string]::IsNullOrEmpty($imageRepo)) {
          Write-NucleusWarning "no image repo found for ${osVersion}, skipping"
          continue
        }

        try {
          # Get anonymous GHCR token
          $tokenResp = Invoke-RestMethod -Uri "https://ghcr.io/token?service=ghcr.io&scope=repository:${imageRepo}:pull"
          $token = $tokenResp.token

          # Query manifest for digest
          $headers = @{
            'Authorization' = "Bearer $token"
            'Accept' = 'application/vnd.oci.image.index.v1+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json'
          }
          $manifestResp = Invoke-WebRequest -Uri "https://ghcr.io/v2/${imageRepo}/manifests/latest" -Headers $headers -Method GET
          $newDigest = if ($manifestResp.Headers['Docker-Content-Digest']) {
            $manifestResp.Headers['Docker-Content-Digest'][0]
          } else { $null }

          if ([string]::IsNullOrEmpty($newDigest)) {
            Write-NucleusWarning "could not fetch digest for ${oldImage}, skipping"
            continue
          }

          if ($oldDigest -ne $newDigest) {
            Write-Update -Section 'vm-setup.tart-images' -Key $osVersion -OldValue "${oldDigest:0:20}..." -NewValue "${newDigest:0:20}..."
            $entry['digest'] = $newDigest
          }
        } catch {
          Write-NucleusWarning "error fetching digest for ${oldImage}: $($_.Exception.Message)"
        }
      }
    }
  }

  # -------------------------------------------------------------------------
  # --verify: compare the mutated in-memory lockfile against the on-disk file
  # and exit without writing. Differs from the write path below, which stamps
  # the timestamp and rewrites the file.
  # -------------------------------------------------------------------------
  if ($Verify) {
    $newJson = ($ht | ConvertTo-Json -Depth 10)
    $oldJson = (Get-Content -Path $lockfileAbs -Raw -Encoding UTF8).Trim()
    if ($newJson -ne $oldJson) {
      Write-NucleusInfo 'lockfile out of date — changes would be made:'
      $oldLines = ($oldJson -split "`n")
      $newLines = ($newJson -split "`n")
      $diff = Compare-Object -ReferenceObject $oldLines -DifferenceObject $newLines
      foreach ($d in $diff) {
        $marker = if ($d.SideIndicator -eq '=>') { '+' } else { '-' }
        Write-NucleusInfo "${marker} $($d.InputObject)"
      }
      exit 1
    }
    Write-NucleusInfo 'lockfile is up to date.'
    exit 0
  }

  # -------------------------------------------------------------------------
  # Atomic write
  # -------------------------------------------------------------------------
  if (-not $changed) {
    Write-NucleusInfo 'no changes — lockfile up to date'
    return
  }

  # Stamp the timestamp only when an actual change is written; a no-change run
  # must not rewrite the file (avoids timestamp churn and spurious git diffs).
  $ht['updated'] = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ssZ' -AsUTC)

  # Convert hashtable back to JSON. Use a depth of 10 for nested objects.
  # NOTE: ConvertTo-Json does NOT sort keys (it preserves insertion order), so the
  # hashtable must already be keyed in the desired order. Append exactly one
  # trailing newline to match the bash writer's `printf '%s\n'` contract.
  $outputJson = ($ht | ConvertTo-Json -Depth 10) + [Environment]::NewLine

  $tmpFile = [System.IO.Path]::GetTempFileName()
  try {
    # Use UTF8 without BOM
    [System.IO.File]::WriteAllText($tmpFile, $outputJson, [System.Text.UTF8Encoding]::new($false))
    Move-Item -Path $tmpFile -Destination $lockfileAbs -Force
    Write-NucleusInfo "wrote ${lockfileRel}"
  } catch {
    if (Test-Path -Path $tmpFile) {
      Remove-Item -Path $tmpFile -Force
    }
    throw
  }
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------
if ($Action -eq 'lockfile') {
  Invoke-LockfileBump
} else {
  Invoke-UpdateAll
  Invoke-LockfileBump
}

Write-NucleusInfo "update workflow completed"
