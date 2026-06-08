# check.ps1 — Consolidated repository validation script (Windows).
#
# Runs all Windows-compatible repository checks in sequence:
#   1. PowerShell syntax validation
#   2. Packer template validation
#   3. Lockfile validation
#   4. Locked DSC validation
#   5. Package manager usage enforcement
#
# Tests (Nix test suite) are run separately via scripts/test.ps1.
# deadnix, shellcheck, and script validation tests are skipped
# on Windows (Nix/ShellCheck not available on Windows runners).
#
# Arguments:
#   (none)        Paths may be provided as positional arguments; passed
#                 through to individual checkers that support path filtering.
#
# Environment variables:
#   NUCLEUS_REPO_ROOT  Override the detected repository root path.
#
# Exit conditions:
#   0 on success; non-zero on any check failure.

#Requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = if ($env:NUCLEUS_REPO_ROOT) { $env:NUCLEUS_REPO_ROOT } else { Split-Path -Parent $PSScriptRoot }
$exitCode = 0

# Process -h|--help
if ($args.Count -gt 0 -and ($args[0] -eq '-h' -or $args[0] -eq '--help')) {
  Write-Output "Usage: check.ps1 [path ...]"
  Write-Output "  Run all Windows-compatible repository validation checks in sequence."
  Write-Output "  With arguments, passes paths through to supporting checkers."
  exit 0
}

$HAS_ARGS = $args.Count -gt 0

# Group paths by extension — each sub-checker receives only files it understands.
$PS1_FILES = @()
$PKR_FILES = @()
if ($HAS_ARGS) {
  foreach ($_f in $args) {
    if ($_f -like '*.ps1')     { $PS1_FILES += $_f }
    if ($_f -like '*.pkr.hcl') { $PKR_FILES += $_f }
  }
}

# ---------------------------------------------------------------------------
# 1. PowerShell syntax validation
# ---------------------------------------------------------------------------
Write-Output "`n=== [1/4] PowerShell syntax validation ==="
if ($PS1_FILES.Count -gt 0) {
  & "$RepoRoot\scripts\check-pwsh.ps1" $PS1_FILES
} elseif (-not $HAS_ARGS) {
  & "$RepoRoot\scripts\check-pwsh.ps1"
} else {
  Write-Output "Skipping (no PowerShell scripts to check)."
}
if ($LASTEXITCODE -ne 0) { $exitCode = $LASTEXITCODE }

# ---------------------------------------------------------------------------
# 2. Packer template validation
# ---------------------------------------------------------------------------
Write-Output "`n=== [2/4] Packer template validation ==="
if ($PKR_FILES.Count -gt 0) {
  & "$RepoRoot\scripts\check-packer.ps1" $PKR_FILES
} elseif (-not $HAS_ARGS) {
  & "$RepoRoot\scripts\check-packer.ps1"
} else {
  Write-Output "Skipping (no Packer templates to check)."
}
if ($LASTEXITCODE -ne 0) { $exitCode = $LASTEXITCODE }

# ---------------------------------------------------------------------------
# 3. Lockfile validation
# ---------------------------------------------------------------------------
Write-Output "`n=== [3/4] Lockfile validation ==="
if (-not $HAS_ARGS) {
  $_lfErrors = 0
  $_lfPath = Join-Path $RepoRoot "src\lockfiles\lockfile.json"
  if (-not (Test-Path $_lfPath)) {
    Write-Output "ERROR: lockfile.json not found at $_lfPath"
    $exitCode = 1
  } else {
    $_lf = Get-Content $_lfPath -Raw | ConvertFrom-Json -AsHashtable

    # Check sections that must be non-empty
    foreach ($_section in @('scoop', 'cargo-binstall', 'bun', 'uv', 'rustup', 'pwsh')) {
      if (-not $_lf.ContainsKey($_section) -or $_lf[$_section].Count -eq 0) {
        Write-Output "ERROR: $_section`: empty or missing section"
        $_lfErrors++
      } else {
        foreach ($_entry in $_lf[$_section].GetEnumerator()) {
          if ([string]::IsNullOrEmpty($_entry.Value) -or @('CHANGEME', '1.0.0') -contains $_entry.Value) {
            Write-Output "ERROR: $_section.$($_entry.Key): placeholder version ($($_entry.Value))"
            $_lfErrors++
          }
        }
      }
    }

    # winget: warn if empty
    if (-not $_lf.ContainsKey('winget')) {
      Write-Output "ERROR: winget: missing section"
      $_lfErrors++
    } elseif ($_lf.winget.Count -gt 0) {
      foreach ($_entry in $_lf.winget.GetEnumerator()) {
        if ([string]::IsNullOrEmpty($_entry.Value) -or @('CHANGEME', '1.0.0') -contains $_entry.Value) {
          Write-Output "ERROR: winget.$($_entry.Key): placeholder version ($($_entry.Value))"
          $_lfErrors++
        }
      }
    } else {
      Write-Output "WARNING: winget: empty section (not yet populated)"
    }

    # vscode: warn if empty
    if (-not $_lf.ContainsKey('vscode')) {
      Write-Output "ERROR: vscode: missing section"
      $_lfErrors++
    } elseif ($_lf.vscode.Count -gt 0) {
      foreach ($_entry in $_lf.vscode.GetEnumerator()) {
        if ([string]::IsNullOrEmpty($_entry.Value) -or @('CHANGEME', '1.0.0') -contains $_entry.Value) {
          Write-Output "ERROR: vscode.$($_entry.Key): placeholder version ($($_entry.Value))"
          $_lfErrors++
        }
      }
    } else {
      Write-Output "WARNING: vscode: empty section (not yet populated)"
    }

    # ollama: must have at least one profile with models
    if (-not $_lf.ContainsKey('ollama') -or $_lf.ollama.Count -eq 0) {
      Write-Output "ERROR: ollama: empty or missing section"
      $_lfErrors++
    } else {
      foreach ($_profile in $_lf.ollama.GetEnumerator()) {
        if ($_profile.Value.Count -eq 0) {
          Write-Output "ERROR: ollama.$($_profile.Key): empty model list"
          $_lfErrors++
        } else {
          for ($_i = 0; $_i -lt $_profile.Value.Count; $_i++) {
            $_model = $_profile.Value[$_i]
            if ([string]::IsNullOrEmpty($_model.name) -or [string]::IsNullOrEmpty($_model.tag)) {
              Write-Output "ERROR: ollama.$($_profile.Key)[$_i]: missing name or tag"
              $_lfErrors++
            }
          }
        }
      }
    }

    if ($_lfErrors -gt 0) {
      Write-Output "ERROR: lockfile.json validation failed with $_lfErrors error(s)"
      $exitCode = 1
    } else {
      Write-Output "lockfile.json validation passed"
    }
  }
} else {
  Write-Output "Skipping lockfile validation (path-scoped mode)."
}
if ($exitCode -ne 0) { /* propagated below */ }

# ---------------------------------------------------------------------------
# 4. Locked DSC validation
# ---------------------------------------------------------------------------
Write-Output "`n=== [4/5] Locked DSC validation ==="
if (-not $HAS_ARGS) {
  $_dscLocked = Join-Path $RepoRoot 'src\hosts\Windows\system-locked.dsc.yml'
  $_lockfilePath = Join-Path $RepoRoot 'src\lockfiles\lockfile.json'

  if (-not (Test-Path $_dscLocked)) {
    Write-Error "$_dscLocked not found - run generate-winget-locked-dsc.ps1 first"
    $exitCode = 1
  } else {
    $_lfErrors = 0

    $_lockfileData = Get-Content $_lockfilePath -Raw | ConvertFrom-Json -AsHashtable
    $_dscYaml = Get-Content $_dscLocked -Raw
    $_dsc = $_dscYaml | ConvertFrom-Yaml -AsHashtable

    # For each winget Package resource with a version pin, verify it matches the lockfile
    foreach ($_resource in $_dsc.properties.resources) {
      if ($_resource.resource -eq 'Microsoft.WinGet.Client/Package' `
          -and $_resource.settings.source -eq 'winget' `
          -and $_resource.settings.version) {
        $_id = $_resource.settings.id
        $_pinnedVer = $_resource.settings.version
        $_lfVer = if ($_lockfileData.winget.ContainsKey($_id)) { $_lockfileData.winget[$_id] } else { '' }

        if ([string]::IsNullOrEmpty($_lfVer)) {
          Write-Output "ERROR: $_dscLocked: $_id has version $_pinnedVer but no lockfile entry"
          $_lfErrors++
        } elseif ($_pinnedVer -ne $_lfVer) {
          Write-Output "ERROR: $_dscLocked: $_id pinned $_pinnedVer but lockfile has $_lfVer"
          $_lfErrors++
        }
      }
    }

    # Check for lockfile entries missing version pins in locked DSC
    foreach ($_entry in $_lockfileData.winget.GetEnumerator()) {
      $_id = $_entry.Key
      $_lfVer = $_entry.Value
      $_foundPin = $false
      foreach ($_resource in $_dsc.properties.resources) {
        if ($_resource.resource -eq 'Microsoft.WinGet.Client/Package' `
            -and $_resource.settings.source -eq 'winget' `
            -and $_resource.settings.id -eq $_id `
            -and $_resource.settings.version) {
          $_foundPin = $true
          break
        }
      }
      if (-not $_foundPin) {
        Write-Output "ERROR: $_dscLocked: $_id ($_lfVer) is in lockfile but missing version pin in locked DSC"
        $_lfErrors++
      }
    }

    if ($_lfErrors -gt 0) {
      Write-Output "ERROR: locked DSC validation failed with $_lfErrors error(s)"
      $exitCode = 1
    } else {
      Write-Output 'Locked DSC validation passed'
    }
  }
} else {
  Write-Output 'Skipping locked DSC validation (path-scoped mode).'
}

# ---------------------------------------------------------------------------
# 5. Package manager usage enforcement
# ---------------------------------------------------------------------------
Write-Output "`n=== [5/5] Package manager usage enforcement ==="
if (-not $HAS_ARGS) {
  $_violations = 0
  # Ban bare pip install and npm install — these bypass the lockfile.
  # uv pip install is allowed.  Exclude self-references.
  $_pipViolations = Select-String -Path @(
    Get-ChildItem -Recurse -Path "$RepoRoot\scripts","$RepoRoot\src","$RepoRoot\tests" `
      -Include *.sh,*.ps1,*.nix `
      -Exclude check.sh,check.ps1 `
      | ForEach-Object { $_.FullName }
    ) -Pattern '(^|[^a-z])pip install([^-]|$)' `
    | Where-Object { $_.Line -notmatch 'uv pip install' }
  if ($_pipViolations) {
    Write-Output "ERROR: bare pip install detected (use uv pip install instead)"
    $_violations++
  }
  $_npmViolations = Select-String -Path @(
    Get-ChildItem -Recurse -Path "$RepoRoot\scripts","$RepoRoot\src","$RepoRoot\tests" `
      -Include *.sh,*.ps1,*.nix `
      | ForEach-Object { $_.FullName }
    ) -Pattern '(^|[^a-z])npm install([^-]|$)'
  if ($_npmViolations) {
    Write-Output "ERROR: bare npm install detected (use bun or nix instead)"
    $_violations++
  }
  if ($_violations -gt 0) {
    $exitCode = $_violations
  } else {
    Write-Output "No package manager violations found."
  }
} else {
  Write-Output "Skipping (path-scoped mode)."
}

if ($exitCode -ne 0) {
  Write-Output "`nSome checks failed with exit code $exitCode."
  exit $exitCode
}
Write-Output "`nAll checks passed."
