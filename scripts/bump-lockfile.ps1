<#
.SYNOPSIS
  Bump version pins in the consolidated lockfile (Windows).

.DESCRIPTION
  Reads src/lockfiles/lockfile.json, queries each available tool for the
  current version of each pinned item, and writes an updated lockfile
  atomically.

  Sections (status — updater):
    winget               updates — winget show --id <id>
    scoop                updates — scoop info <pkg>
    cargo-binstall       updates — crates.io API
    cargo                alias — selects the cargo-binstall section
    bun                  updates — npm view <pkg> version
    uv                   updates — uv tool list
    rustup               updates — rustup toolchain list + rustc +<ch> --version
    pwsh                 updates — Find-Module via pwsh
    homebrew             updates — parent section; selects brews, casks, masApps
    homebrew.brews       updates — brew list --versions
    homebrew.casks       updates — brew list --cask --versions
    homebrew.masApps     no updater (manual) — App Store IDs, not versions
    vscode               updates — code / code-insiders --list-extensions --show-versions
    ollama               updates — ollama show <name>:<tag> --format json
    vm-setup             updates — parent section; selects nixos-iso, tart-images, windows
    vm-setup.nixos-iso   updates — NixOS channel latest ISO URL and SHA-256
    vm-setup.tart-images updates — GHCR OCI registry digest
    vm-setup.windows     no updater (manual) — digest recording not implemented
    camilladsp           updates — GitHub releases API
    camillagui-backend   updates — GitHub releases API
    sccache              updates — GitHub releases API
    starship             updates — GitHub releases API
    source-builds        no updater (manual) — VCS rev + version
    version              no updater (manual) — schema version
  Run -ListSections for the machine-readable name list.

.PARAMETER Sections
  Comma-separated list of sections to update; defaults to all sections when
  omitted. 'cargo' is an alias for 'cargo-binstall'; the legacy bare names
  'nixos-iso' and 'tart-images' are accepted as aliases for
  'vm-setup.nixos-iso' and 'vm-setup.tart-images'. A parent section name
  (vm-setup, homebrew) selects all of its dotted children. POSIX equivalent:
  --sections.

.PARAMETER Verify
  Check whether the lockfile is up to date without writing. Exits 0 when
  unchanged, 1 with the pending diff otherwise. POSIX equivalent: --verify.

.PARAMETER ListSections
  Print the valid section names, one per line, and exit. POSIX equivalent:
  --list-sections.

.PARAMETER Help
  Show this help message. POSIX equivalent: --help.

.EXAMPLE
  .\bump-lockfile.ps1
  .\bump-lockfile.ps1 -Sections winget,scoop
  .\bump-lockfile.ps1 -ListSections
  .\bump-lockfile.ps1 -Sections cargo -Verify

.NOTES
  Environment variable: NUCLEUS_REPO_ROOT (optional, overrides repo root detection).
  Environment variable: NUCLEUS_OLLAMA_HOST (optional, Ollama daemon address for admin CLI commands; default: 127.0.0.1:11434).
  Exit codes: 0 on success; non-zero on failure.
#>
[CmdletBinding()]
param(
  [Alias("s")]
  [string]$Sections,
  [Alias("h")]
  [switch]$Help,
  [Alias("l")]
  [switch]$ListSections,
  [Alias("v")]
  [switch]$Verify
)

$ErrorActionPreference = 'Stop'

# Canonical section registry: the valid section names in alphabetical order,
# matching the bash lane's --list-sections output. 'cargo' is the alias that
# selects the cargo-binstall updater; the legacy bare names nixos-iso and
# tart-images are accepted as input tokens only (not listed).
$validSections = @(
  'bun',
  'camilladsp',
  'camillagui-backend',
  'cargo',
  'cargo-binstall',
  'homebrew',
  'homebrew.brews',
  'homebrew.casks',
  'homebrew.masApps',
  'ollama',
  'pwsh',
  'rustup',
  'sccache',
  'scoop',
  'source-builds',
  'starship',
  'uv',
  'version',
  'vm-setup',
  'vm-setup.nixos-iso',
  'vm-setup.tart-images',
  'vm-setup.windows',
  'vscode',
  'winget'
)
$validTokens = @($validSections) + @('nixos-iso', 'tart-images')

if ($Help) {
  Get-Help $PSCommandPath -Detailed
  return
}

if ($ListSections) {
  foreach ($section in $validSections) {
    Write-Output $section
  }
  return
}

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
$repoRoot = if ($env:NUCLEUS_REPO_ROOT) {
  $env:NUCLEUS_REPO_ROOT
} else {
  (Resolve-Path -Path (Join-Path -Path $PSScriptRoot -ChildPath '..')).Path
}

$modulePath = Join-Path $PSScriptRoot '..\src\platforms\Windows\modules\Format-NucleusOutput.psm1'
Import-Module $modulePath -Force -DisableNameChecking

# ---------------------------------------------------------------------------
# Section selection — validate and normalize explicit -Sections tokens
# ---------------------------------------------------------------------------
# Unknown tokens error out before any updater or network query runs. Written
# via Write-NucleusError with -ErrorAction Continue so the message survives
# $ErrorActionPreference 'Stop' while still exiting 1.
$sectionTokens = if ([string]::IsNullOrEmpty($Sections)) {
  @()
} else {
  foreach ($token in $Sections.Split(',')) {
    $t = $token.Trim()
    if ($validTokens -notcontains $t) {
      # -CommandName is explicit: the module's Get-NucleusCommandName default
      # ($PSCommandPath) resolves to the module file, not this script.
      Write-NucleusError -CommandName bump-lockfile -Message "unknown section '$t' (valid: $($validSections -join ','))" -ErrorAction Continue
      exit 1
    }
  }
  # Normalize aliases to canonical dotted form once; Test-SectionEnabled then
  # needs only equality plus parent-prefix matching (vm-setup → its children).
  @($Sections.Split(',') | ForEach-Object {
    $t = $_.Trim()
    if ($t -eq 'cargo') { 'cargo-binstall' }
    elseif ($t -eq 'nixos-iso') { 'vm-setup.nixos-iso' }
    elseif ($t -eq 'tart-images') { 'vm-setup.tart-images' }
    else { $t }
  })
}

$lockfileRel = 'src/lockfiles/lockfile.json'
$lockfileAbs = Join-Path -Path $repoRoot -ChildPath $lockfileRel

if (-not (Test-Path -Path $lockfileAbs)) {
  Write-NucleusError "lockfile not found at $lockfileAbs"
  exit 1
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
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
  # Tokens are pre-normalized to canonical dotted form (cargo → cargo-binstall,
  # nixos-iso → vm-setup.nixos-iso); a parent token (vm-setup, homebrew) also
  # selects all of its dotted children.
  foreach ($token in $sectionTokens) {
    if ($Name -eq $token -or $Name.StartsWith("$token.")) { return $true }
  }
  return $false
}

function Set-LockfileValue {
  [CmdletBinding(SupportsShouldProcess)]
  param(
    [hashtable]$Lockfile,
    [string]$Section,
    [string]$Key,
    [string]$Value
  )
  if (-not $Lockfile.ContainsKey($Section)) {
    $Lockfile[$Section] = @{}
  }
  if ($PSCmdlet.ShouldProcess("${Section}.${Key}", 'Set value')) {
    $Lockfile[$Section][$Key] = $Value
  }
}

function Get-LockfileValue {
  param(
    [hashtable]$Lockfile,
    [string]$Section,
    [string]$Key
  )
  if ($Lockfile.ContainsKey($Section) -and $Lockfile[$Section] -is [hashtable] -and $Lockfile[$Section].ContainsKey($Key)) {
    return $Lockfile[$Section][$Key]
  }
  return $null
}

# ---------------------------------------------------------------------------
# Read lockfile
# ---------------------------------------------------------------------------
$rawJson = Get-Content -Path $lockfileAbs -Raw -Encoding UTF8
$lockfile = $rawJson | ConvertFrom-Json -Depth 32

# We'll work with a mutable hashtable for easier manipulation, then convert back.
# ConvertFrom-Json with -AsHashtable was added in PowerShell 6.0. We need to
# use a different approach for compatibility. Use a helper to convert PSObject
# to hashtable recursively.
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

$ht = ConvertTo-Hashtable $lockfile

# Change tracking: the timestamp is stamped and the file written only when at
# least one section produced a change (set by Write-Update). Stamping before
# the queries would make --verify always fail and rewrite the file on every
# run (timestamp churn).
$changed = $false

# ---------------------------------------------------------------------------
# winget — winget show --id <id>
# ---------------------------------------------------------------------------
if (Test-SectionEnabled 'winget') {
  if (Get-Command -Name 'winget' -ErrorAction SilentlyContinue) {
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

# ---------------------------------------------------------------------------
# scoop — scoop info <pkg>
# ---------------------------------------------------------------------------
if (Test-SectionEnabled 'scoop') {
  if (Get-Command -Name 'scoop' -ErrorAction SilentlyContinue) {
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

# ---------------------------------------------------------------------------
# cargo-binstall — crates.io API; -Sections cargo selects this section too
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# bun — npm view <pkg> version
# ---------------------------------------------------------------------------
if (Test-SectionEnabled 'bun') {
  if (Get-Command -Name 'npm' -ErrorAction SilentlyContinue) {
    if ($ht.ContainsKey('bun') -and $ht['bun'] -is [hashtable]) {
      foreach ($key in @($ht['bun'].Keys)) {
        $old = $ht['bun'][$key]
        # check-suppress:suppression_doc: probe -- package may not exist; stderr suppressed for clean output.
        $result = & npm view $key version 2>$null
        if ($result) {
          $new = $result.Trim()
          if (-not [string]::IsNullOrEmpty($new) -and $new -ne $old) {
            Write-Update -Section 'bun' -Key $key -OldValue $old -NewValue $new
            $ht['bun'][$key] = $new
          }
        }
      }
    }
  } else {
    Write-NucleusWarning 'npm not found — skipping bun section'
  }
}

# ---------------------------------------------------------------------------
# uv — uv tool list
# ---------------------------------------------------------------------------
if (Test-SectionEnabled 'uv') {
  if (Get-Command -Name 'uv' -ErrorAction SilentlyContinue) {
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

# ---------------------------------------------------------------------------
# rustup — rustc +<channel> --version
# ---------------------------------------------------------------------------
if (Test-SectionEnabled 'rustup') {
  if (Get-Command -Name 'rustup' -ErrorAction SilentlyContinue) {
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
          $match = [regex]::Match($versionOutput, '\d{4}-\d{2}-\d{2}')
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

# ---------------------------------------------------------------------------
# pwsh — Find-Module via pwsh -NoProfile
# ---------------------------------------------------------------------------
if (Test-SectionEnabled 'pwsh') {
  if (Get-Command -Name 'pwsh' -ErrorAction SilentlyContinue) {
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

# ---------------------------------------------------------------------------
# homebrew — brew list --versions, brew list --cask --versions
# ---------------------------------------------------------------------------
if ((Test-SectionEnabled 'homebrew.brews') -or (Test-SectionEnabled 'homebrew.casks')) {
  # check-suppress:suppression_doc: probe whether tool is installed; Get-Command throws when absent.
  if (Get-Command -Name 'brew' -ErrorAction SilentlyContinue) {
    if (Test-SectionEnabled 'homebrew.brews') {
      if ($ht.ContainsKey('homebrew') -and $ht['homebrew'] -is [hashtable] -and $ht['homebrew'].ContainsKey('brews') -and $ht['homebrew']['brews'] -is [hashtable]) {
        # check-suppress:suppression_doc: probe -- package may not exist; stderr suppressed for clean output.
        $brewList = & brew list --versions 2>$null
        $brewVersions = @{}
        foreach ($line in $brewList) {
          $parts = $line.Trim() -split '\s+'
          if ($parts.Count -ge 2) {
            $brewVersions[$parts[0]] = $parts[1]
          }
        }
        foreach ($key in @($ht['homebrew']['brews'].Keys)) {
          $old = $ht['homebrew']['brews'][$key]
          if ($brewVersions.ContainsKey($key)) {
            $new = $brewVersions[$key]
            if ($new -ne $old) {
              Write-Update -Section 'homebrew.brews' -Key $key -OldValue $old -NewValue $new
              $ht['homebrew']['brews'][$key] = $new
            }
          }
        }
      }
    }
    if (Test-SectionEnabled 'homebrew.casks') {
      if ($ht.ContainsKey('homebrew') -and $ht['homebrew'] -is [hashtable] -and $ht['homebrew'].ContainsKey('casks') -and $ht['homebrew']['casks'] -is [hashtable]) {
        # check-suppress:suppression_doc: probe -- package may not exist; stderr suppressed for clean output.
        $caskList = & brew list --cask --versions 2>$null
        $caskVersions = @{}
        foreach ($line in $caskList) {
          $parts = $line.Trim() -split '\s+'
          if ($parts.Count -ge 2) {
            $caskVersions[$parts[0]] = $parts[1]
          }
        }
        foreach ($key in @($ht['homebrew']['casks'].Keys)) {
          $old = $ht['homebrew']['casks'][$key]
          if ($caskVersions.ContainsKey($key)) {
            $new = $caskVersions[$key]
            if ($new -ne $old) {
              Write-Update -Section 'homebrew.casks' -Key $key -OldValue $old -NewValue $new
              $ht['homebrew']['casks'][$key] = $new
            }
          }
        }
      }
    }
  } else {
    Write-NucleusWarning 'brew unavailable — skipping homebrew section'
  }
}

# ---------------------------------------------------------------------------
# vscode — code / code-insiders --list-extensions --show-versions
# ---------------------------------------------------------------------------
if (Test-SectionEnabled 'vscode') {
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
    Write-NucleusWarning 'code/code-insiders not found — skipping vscode section'
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

    if ($ht.ContainsKey('vscode') -and $ht['vscode'] -is [hashtable]) {
      foreach ($key in @($ht['vscode'].Keys)) {
        $old = $ht['vscode'][$key]
        if ($vscodeExts.ContainsKey($key)) {
          $new = $vscodeExts[$key]
          if (-not [string]::IsNullOrEmpty($new) -and $new -ne $old) {
            Write-Update -Section 'vscode' -Key $key -OldValue $old -NewValue $new
            $ht['vscode'][$key] = $new
          }
        }
      }
    }
  }
}

# ---------------------------------------------------------------------------
# ollama — ollama show <name>:<tag> --format json
# ---------------------------------------------------------------------------
if (Test-SectionEnabled 'ollama') {  # Point at the Ollama daemon directly, bypassing the LiteLLM proxy that
  # home.sessionVariables.OLLAMA_HOST (127.0.0.1:4000) normally routes to.
  if (Get-Command -Name 'ollama' -ErrorAction SilentlyContinue) {
    if ($ht.ContainsKey('ollama') -and $ht['ollama'] -is [hashtable]) {
    foreach ($hostName in $ht['ollama'].Keys) {
      $models = $ht['ollama'][$hostName]
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

# ---------------------------------------------------------------------------
# GitHub release scalars — camilladsp, camillagui-backend, sccache, starship
# ---------------------------------------------------------------------------
function Update-GitHubReleaseScalar {
  [CmdletBinding(SupportsShouldProcess)]
  param([string]$Key, [string]$Repo)
  if (-not $ht.ContainsKey($Key) -or $ht[$Key] -is [hashtable]) { return }
  $old = $ht[$Key]
  try {
    # WHY: unauthenticated GitHub API requests are rate-limited to 60/hr, acceptable for a manual command.
    $release = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases/latest" -Headers @{ 'User-Agent' = 'nucleus-bump-lockfile' }
    $new = [string]$release.tag_name
    if ($new -like 'v*') { $new = $new.Substring(1) }
    if (-not [string]::IsNullOrEmpty($new) -and $new -ne $old) {
      if ($PSCmdlet.ShouldProcess($Key, 'Set value')) {
        Write-Update -Section $Key -Key $Key -OldValue $old -NewValue $new
        $ht[$Key] = $new
      }
    }
  } catch {
    Write-NucleusWarning "${Key}: GitHub releases query failed — keeping current version ($($_.Exception.Message))"
  }
}

if (Test-SectionEnabled 'camilladsp') { Update-GitHubReleaseScalar -Key 'camilladsp' -Repo 'HEnquist/camilladsp' }
if (Test-SectionEnabled 'camillagui-backend') { Update-GitHubReleaseScalar -Key 'camillagui-backend' -Repo 'HEnquist/camillagui-backend' }
if (Test-SectionEnabled 'sccache') { Update-GitHubReleaseScalar -Key 'sccache' -Repo 'mozilla/sccache' }
if (Test-SectionEnabled 'starship') { Update-GitHubReleaseScalar -Key 'starship' -Repo 'starship/starship' }

# ---------------------------------------------------------------------------
# nixos-iso — Query NixOS channel for latest ISO URL and SHA-256
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# tart-images — Query GHCR OCI registry for Cirrus CI macOS base image digests
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# No-updater sections — visible skip when explicitly selected
# ---------------------------------------------------------------------------
# Only the default all-sections run must stay silent: these names have no
# updater and selecting them explicitly should say so instead of doing nothing.
foreach ($token in $sectionTokens) {
  if ($token -in @('source-builds', 'homebrew.masApps', 'vm-setup.windows', 'version')) {
    Write-NucleusWarning "section '$token' has no updater — kept manual"
  }
}

# ---------------------------------------------------------------------------
# Verify mode — diff against current lockfile without writing
# ---------------------------------------------------------------------------
if ($Verify) {
  $outputJson = $ht | ConvertTo-Json -Depth 10
  # Canonical comparison: parse the committed file and re-serialize it with the
  # identical ConvertTo-Json call used for the write. Comparing against the raw
  # file text would always mismatch because key order and formatting differ
  # between the file and PowerShell's serializer.
  $currentJson = ConvertTo-Hashtable (Get-Content -Path $lockfileAbs -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 32) | ConvertTo-Json -Depth 10
  if ($outputJson -ne $currentJson) {
    Write-NucleusInfo "--verify: lockfile out of date — changes would be made:"
    $diffLines = Compare-Object ([string[]]($currentJson -split "`n")) ([string[]]($outputJson -split "`n"))
    $diffLines | ForEach-Object { Write-Output ("{0} {1}" -f $_.SideIndicator, $_.InputObject) }
    exit 1
  }
  Write-NucleusInfo "--verify: lockfile is up to date."
  exit 0
}

# ---------------------------------------------------------------------------
# Atomic write
# ---------------------------------------------------------------------------
if (-not $changed) {
  Write-NucleusInfo 'no changes — lockfile up to date'
  exit 0
}

# Stamp the timestamp only when an actual change is written; a no-change run
# must not rewrite the file (avoids timestamp churn and spurious git diffs).
$ht['updated'] = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ssZ' -AsUTC)

# Convert hashtable back to sorted JSON. Use a depth of 10 for nested objects.
$outputJson = $ht | ConvertTo-Json -Depth 10

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
