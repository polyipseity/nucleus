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
#   vm-setup      VM image artifact pins (nixos-iso, tart-images, windows). Use -Sections nixos-iso etc. for sub-sections.

.PARAMETER Sections
  Comma-separated list of sections to update. If omitted, all sections are updated.

.PARAMETER Help
  Show this help message.

.EXAMPLE
  .\bump-lockfile.ps1
  .\bump-lockfile.ps1 -Sections winget,scoop

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

function Test-SectionEnabled {
  param([string]$Name)
  if ([string]::IsNullOrEmpty($Sections)) { return $true }
  return $Sections.Split(',') -contains $Name
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
if ((Test-SectionEnabled 'winget') -and (Test-CommandAvailable 'winget')) {
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
if ((Test-SectionEnabled 'scoop') -and (Test-CommandAvailable 'scoop')) {
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
if (Test-SectionEnabled 'cargo-binstall') {
  Write-SkipAll -Section 'cargo-binstall (no reliable CLI query available)'
}

# ---------------------------------------------------------------------------
# bun — npm view <pkg> version, gated on bun availability
# ---------------------------------------------------------------------------
if ((Test-SectionEnabled 'bun') -and (Test-CommandAvailable 'bun')) {
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
if ((Test-SectionEnabled 'uv') -and (Test-CommandAvailable 'uv')) {
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
if ((Test-SectionEnabled 'rustup') -and (Test-CommandAvailable 'rustup')) {
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
if ((Test-SectionEnabled 'pwsh') -and (Test-CommandAvailable 'pwsh')) {
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
if (Test-SectionEnabled 'vscode') {
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
}

# ---------------------------------------------------------------------------
# ollama — ollama show <name>:<tag> --format json
# ---------------------------------------------------------------------------
if ((Test-SectionEnabled 'ollama') -and (Test-CommandAvailable 'ollama')) {  # Point at the Ollama daemon directly, bypassing the LiteLLM proxy that
  # home.sessionVariables.OLLAMA_HOST (127.0.0.1:4000) normally routes to.
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

        $ollamaHostAddr = if ($env:NUCLEUS_OLLAMA_HOST) { $env:NUCLEUS_OLLAMA_HOST } else { '127.0.0.1:11434' }
        try {
          $oldOllamaHost = $env:OLLAMA_HOST
          $env:OLLAMA_HOST = $ollamaHostAddr
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
          Write-Warning "bump-lockfile: ollama show failed for ${name}:${tag}; keeping existing digest"
        }
      }
    }
  }
} else {
  Write-Skip -Tool 'ollama' -Section 'ollama'
}

# ---------------------------------------------------------------------------
# nixos-iso — Query NixOS channel for latest ISO URL and SHA-256
# ---------------------------------------------------------------------------
if ((Test-SectionEnabled 'vm-setup') -or (Test-SectionEnabled 'nixos-iso')) {
  if ($ht.ContainsKey('vm-setup') -and $ht['vm-setup'].ContainsKey('nixos-iso') -and $ht['vm-setup']['nixos-iso'] -is [hashtable]) {
    foreach ($arch in $ht['vm-setup']['nixos-iso'].Keys) {
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
        Write-Warning "bump-lockfile: could not resolve ${latestUrl} for ${arch}: $($_.Exception.Message)"
        continue
      }

      $sha256Url = "${resolvedUrl}.sha256"
      try {
        $sha256Content = (Invoke-WebRequest -Uri $sha256Url -UseBasicParsing).Content
        if ($sha256Content -match '^([0-9a-f]{64})') {
          $newSha256 = $Matches[1]
        } else {
          Write-Warning "bump-lockfile: could not parse checksum from ${sha256Url}"
          continue
        }
      } catch {
        Write-Warning "bump-lockfile: could not fetch checksum for ${arch}: $($_.Exception.Message)"
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
if ((Test-SectionEnabled 'vm-setup') -or (Test-SectionEnabled 'tart-images')) {
  if ($ht.ContainsKey('vm-setup') -and $ht['vm-setup'].ContainsKey('tart-images') -and $ht['vm-setup']['tart-images'] -is [hashtable]) {
    foreach ($osVersion in $ht['vm-setup']['tart-images'].Keys) {
      $entry = $ht['vm-setup']['tart-images'][$osVersion]
      $oldImage = $entry['image']
      $oldDigest = $entry['digest']
      if ([string]::IsNullOrEmpty($oldImage)) { continue }

      # Extract OCI repo name from image URI
      $imageRepo = $oldImage -replace '^ghcr\.io/', ''
      if ([string]::IsNullOrEmpty($imageRepo)) {
        Write-Warning "bump-lockfile: no image repo found for ${osVersion}, skipping"
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
          Write-Warning "bump-lockfile: could not fetch digest for ${oldImage}, skipping"
          continue
        }

        if ($oldDigest -ne $newDigest) {
          Write-Update -Section 'vm-setup.tart-images' -Key $osVersion -OldValue "${oldDigest:0:20}..." -NewValue "${newDigest:0:20}..."
          $entry['digest'] = $newDigest
        }
      } catch {
        Write-Warning "bump-lockfile: error fetching digest for ${oldImage}: $($_.Exception.Message)"
      }
    }
  }
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
