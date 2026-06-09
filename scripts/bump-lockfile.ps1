<#
.SYNOPSIS
  Bump version pins in the consolidated lockfile (Windows).

.DESCRIPTION
  Reads src/lockfiles/lockfile.json, queries each available tool for the
  current version of each pinned item, and writes an updated lockfile
  atomically.

  Sections:
    winget        winget show --id <id>
    scoop         scoop info <pkg>
    cargo-binstall Keep current version (no reliable CLI query)
    bun           npm view <pkg> version
    uv            uv tool list
    rustup        rustup toolchain list + rustc +<ch> --version
    pwsh          Find-Module via pwsh
    vscode        code / code-insiders --list-extensions --show-versions
    ollama        ollama show <name>:<tag> --format json

.PARAMETER Help
  Show this help message.

.EXAMPLE
  .\bump-lockfile.ps1

.NOTES
  Environment variable: NUCLEUS_REPO_ROOT (optional, overrides repo root detection).
  Exit codes: 0 on success; non-zero on failure.
#>
[CmdletBinding()]
param(
  [Alias("h")]
  [switch]$Help
)

$ErrorActionPreference = 'Stop'

if ($Help) {
  Get-Help $PSCommandPath -Detailed
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
$lockfileRel = 'src/lockfiles/lockfile.json'
$lockfileAbs = Join-Path -Path $repoRoot -ChildPath $lockfileRel

if (-not (Test-Path -Path $lockfileAbs)) {
  Write-Error "bump-lockfile: lockfile not found at $lockfileAbs"
  exit 1
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
function Write-Update {
  param([string]$Section, [string]$Key, [string]$OldValue, [string]$NewValue)
  Write-Output "bump-lockfile: updating ${Section}.${Key} from ${OldValue} to ${NewValue}"
}

function Write-Skip {
  param([string]$Tool, [string]$Section)
  Write-Output "bump-lockfile: ${Tool} not available, skipping ${Section} section"
}

function Write-SkipAll {
  param([string]$Section)
  Write-Output "bump-lockfile: skipping ${Section} section"
}

function Test-CommandAvailable {
  param([string]$Command)
  return [bool](Get-Command -Name $Command -ErrorAction SilentlyContinue)
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

# Update timestamp
$ht['updated'] = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ssZ' -AsUTC)

# ---------------------------------------------------------------------------
# winget — winget show --id <id>
# ---------------------------------------------------------------------------
if (Test-CommandAvailable 'winget') {
  if ($ht.ContainsKey('winget') -and $ht['winget'] -is [hashtable]) {
    foreach ($key in $ht['winget'].Keys) {
      $old = $ht['winget'][$key]
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
  Write-Skip -Tool 'winget' -Section 'winget'
}

# ---------------------------------------------------------------------------
# scoop — scoop info <pkg>
# ---------------------------------------------------------------------------
if (Test-CommandAvailable 'scoop') {
  if ($ht.ContainsKey('scoop') -and $ht['scoop'] -is [hashtable]) {
    foreach ($key in $ht['scoop'].Keys) {
      $old = $ht['scoop'][$key]
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
  Write-Skip -Tool 'scoop' -Section 'scoop'
}

# ---------------------------------------------------------------------------
# cargo-binstall — keep current version
# ---------------------------------------------------------------------------
Write-SkipAll -Section 'cargo-binstall (no reliable CLI query available)'

# ---------------------------------------------------------------------------
# bun — npm view <pkg> version, gated on bun availability
# ---------------------------------------------------------------------------
if (Test-CommandAvailable 'bun') {
  if ($ht.ContainsKey('bun') -and $ht['bun'] -is [hashtable]) {
    foreach ($key in $ht['bun'].Keys) {
      $old = $ht['bun'][$key]
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
  Write-Skip -Tool 'bun' -Section 'bun'
}

# ---------------------------------------------------------------------------
# uv — uv tool list
# ---------------------------------------------------------------------------
if (Test-CommandAvailable 'uv') {
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
      foreach ($key in $ht['uv'].Keys) {
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
  Write-Skip -Tool 'uv' -Section 'uv'
}

# ---------------------------------------------------------------------------
# rustup — rustc +<channel> --version
# ---------------------------------------------------------------------------
if (Test-CommandAvailable 'rustup') {
  # Get installed toolchains
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
    foreach ($key in $ht['rustup'].Keys) {
      $old = $ht['rustup'][$key]
      if ($toolchainSet.ContainsKey($key)) {
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
  Write-Skip -Tool 'rustup' -Section 'rustup'
}

# ---------------------------------------------------------------------------
# pwsh — Find-Module via pwsh -NoProfile
# ---------------------------------------------------------------------------
if (Test-CommandAvailable 'pwsh') {
  if ($ht.ContainsKey('pwsh') -and $ht['pwsh'] -is [hashtable]) {
    foreach ($key in $ht['pwsh'].Keys) {
      $old = $ht['pwsh'][$key]
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
  Write-Skip -Tool 'pwsh' -Section 'pwsh'
}

# ---------------------------------------------------------------------------
# vscode — code / code-insiders --list-extensions --show-versions
# ---------------------------------------------------------------------------
$vscodeOutput = $null
if (Test-CommandAvailable 'code') {
  $vscodeOutput = & code --list-extensions --show-versions 2>$null
} elseif (Test-CommandAvailable 'code-insiders') {
  $vscodeOutput = & code-insiders --list-extensions --show-versions 2>$null
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
    foreach ($key in $ht['vscode'].Keys) {
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
} else {
  Write-Skip -Tool 'vscode' -Section 'vscode'
}

# ---------------------------------------------------------------------------
# ollama — ollama show <name>:<tag> --format json
# ---------------------------------------------------------------------------
if (Test-CommandAvailable 'ollama') {  # Point at the Ollama daemon directly, bypassing the LiteLLM proxy that
  # home.sessionVariables.OLLAMA_HOST (127.0.0.1:4000) normally routes to.
  $env:OLLAMA_HOST = '127.0.0.1:11434'
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

        try {
          $ollamaInfo = & ollama show "${name}:${tag}" --format json 2>$null
          if ($ollamaInfo) {
            $ollamaJson = $ollamaInfo | Out-String | ConvertFrom-Json -Depth 10
            $newDigest = $ollamaJson.digest
            if (-not [string]::IsNullOrEmpty($newDigest) -and $newDigest -ne $oldDigest) {
              Write-Update -Section "ollama ($hostName)" -Key "${name}:${tag}" -OldValue ($oldDigest ?? 'none') -NewValue $newDigest
              $entry['digest'] = $newDigest
            }
          }
        } catch {
          Write-Warning "bump-lockfile: ollama show failed for ${name}:${tag}; keeping existing digest"
        }
      }
    }
  }
} else {
  Write-Skip -Tool 'ollama' -Section 'ollama'
}

# ---------------------------------------------------------------------------
# Atomic write
# ---------------------------------------------------------------------------
# Convert hashtable back to sorted JSON. Use a depth of 10 for nested objects.
$outputJson = $ht | ConvertTo-Json -Depth 10

$tmpFile = [System.IO.Path]::GetTempFileName()
try {
  # Use UTF8 without BOM
  [System.IO.File]::WriteAllText($tmpFile, $outputJson, [System.Text.UTF8Encoding]::$false)
  Move-Item -Path $tmpFile -Destination $lockfileAbs -Force
  Write-Output "bump-lockfile: wrote ${lockfileRel}"
} catch {
  if (Test-Path -Path $tmpFile) {
    Remove-Item -Path $tmpFile -Force
  }
  throw
}
