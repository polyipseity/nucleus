# check.ps1 — Consolidated repository validation script (Windows).
#
# Runs all Windows-compatible repository checks in sequence:
#   1. PowerShell syntax validation
#   2. Packer template validation
#   3. Service registry validation
#   4. Lockfile validation
#   5. Locked DSC validation
#   6. Package manager usage enforcement
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

$_step = 0

# ---------------------------------------------------------------------------
# 1. PowerShell syntax validation
# ---------------------------------------------------------------------------
Write-Output ("`n=== [{0}] PowerShell syntax validation ===" -f (++$_step))
if ($PS1_FILES.Count -gt 0) {
  & "$RepoRoot\scripts\check-pwsh.ps1" -SyntaxOnly $PS1_FILES
} elseif (-not $HAS_ARGS) {
  & "$RepoRoot\scripts\check-pwsh.ps1" -SyntaxOnly
} else {
  Write-Output "Skipping (no PowerShell scripts to check)."
}
if ($LASTEXITCODE -ne 0) { $exitCode = $LASTEXITCODE }

# ---------------------------------------------------------------------------
# 2. Packer template validation
# ---------------------------------------------------------------------------
Write-Output ("`n=== [{0}] Packer template validation ===" -f (++$_step))
if ($PKR_FILES.Count -gt 0) {
  & "$RepoRoot\scripts\check-packer.ps1" $PKR_FILES
} elseif (-not $HAS_ARGS) {
  & "$RepoRoot\scripts\check-packer.ps1"
} else {
  Write-Output "Skipping (no Packer templates to check)."
}
if ($LASTEXITCODE -ne 0) { $exitCode = $LASTEXITCODE }

# ---------------------------------------------------------------------------
# 3. Service registry validation
# ---------------------------------------------------------------------------
Write-Output ("`n=== [{0}] Service registry validation ===" -f (++$_step))
if (-not $HAS_ARGS) {
  $_svcJson = Join-Path $RepoRoot "src\modules\services.json"
  $_svcErrors = 0

  if (-not (Test-Path $_svcJson)) {
    Write-Output "ERROR: services.json not found at $_svcJson"
    $_svcErrors++
  } else {
    $_svc = Get-Content $_svcJson -Raw | ConvertFrom-Json -AsHashtable

    foreach ($_svcName in $_svc.Keys) {
      $_entry = $_svc[$_svcName]
      if ($_entry -isnot [hashtable]) { continue }
      if (-not $_entry.ContainsKey('displayName') -or [string]::IsNullOrEmpty($_entry.displayName)) {
        Write-Output "ERROR: services.json: '$_svcName' missing displayName"
        $_svcErrors++
      }
      if (-not $_entry.ContainsKey('platforms') -or $_entry.platforms.Count -eq 0) {
        Write-Output "ERROR: services.json: '$_svcName' missing or empty platforms"
        $_svcErrors++
      } else {
        foreach ($_plat in $_entry.platforms.Keys) {
          $_pEntry = $_entry.platforms[$_plat]
          $_type = $_pEntry.type
          if ($_type -notin @('launchctl', 'systemctl', 'native', 'schtask', 'omitted')) {
            Write-Output "ERROR: services.json: '$_svcName' platform '$_plat' has invalid type '$_type'"
            $_svcErrors++
          }
          $_hasRequired = switch ($_type) {
            'launchctl' { -not [string]::IsNullOrEmpty($_pEntry.service) }
            'systemctl' { -not [string]::IsNullOrEmpty($_pEntry.service) }
            'native'    { -not [string]::IsNullOrEmpty($_pEntry.service) }
            'schtask'   { -not [string]::IsNullOrEmpty($_pEntry.taskPath) }
            'omitted'   { -not [string]::IsNullOrEmpty($_pEntry.justification) }
            default     { $false }
          }
          if (-not $_hasRequired) {
            Write-Output "ERROR: services.json: '$_svcName' platform '$_plat' missing required fields for type '$_type'"
            $_svcErrors++
          }
        }
      }
    }
  }

  if ($_svcErrors -gt 0) {
    Write-Output "ERROR: services.json validation failed with $_svcErrors error(s)"
    $exitCode = 1
  } else {
    Write-Output "services.json validation passed"

    # Validate user-scoped platform entries have justification.
    foreach ($_svcName in $_svc.Keys) {
      $_entry = $_svc[$_svcName]
      if ($_entry -isnot [hashtable]) { continue }
      if ($_entry.ContainsKey('platforms')) {
        foreach ($_plat in $_entry.platforms.Keys) {
          $_pEntry = $_entry.platforms[$_plat]
          $_domainScope = if ($_pEntry.ContainsKey('domain')) { $_pEntry.domain } elseif ($_pEntry.ContainsKey('scope')) { $_pEntry.scope } else { $null }
          $_hasJustification = $_pEntry.ContainsKey('justification') -and -not [string]::IsNullOrEmpty($_pEntry.justification)
          if ($_domainScope -eq 'user' -and -not $_hasJustification) {
            Write-Output "ERROR: services.json: '$_svcName' platform '$_plat' is user-scoped but missing justification"
            $_svcErrors++
          }
        }
      }
    }

    # Validate that service names in users.json services blocks exist in services.json.
    $_usersJson = Join-Path $RepoRoot "src\modules\users.json"
    if (Test-Path $_usersJson) {
      $_users = Get-Content $_usersJson -Raw | ConvertFrom-Json -AsHashtable
      foreach ($_username in $_users.Keys) {
        $_userEntry = $_users[$_username]
        if ($_userEntry.ContainsKey('services')) {
          foreach ($_svcKey in $_userEntry.services.Keys) {
            if (-not $_svc.ContainsKey($_svcKey)) {
              Write-Output "ERROR: ${_usersJson}: user '$_username' references unknown service '$_svcKey'"
              $_svcErrors++
            }
          }
        }
      }
    }

    # Windows users.json
    $_winUsersJson = Join-Path $RepoRoot "src\hosts\Windows\users.json"
    if (Test-Path $_winUsersJson) {
      $_winUsers = (Get-Content $_winUsersJson -Raw | ConvertFrom-Json -AsHashtable).users
      if ($_winUsers) {
        foreach ($_username in $_winUsers.Keys) {
          $_userEntry = $_winUsers[$_username]
          if ($_userEntry.ContainsKey('services')) {
            foreach ($_svcKey in $_userEntry.services.Keys) {
              if (-not $_svc.ContainsKey($_svcKey)) {
                Write-Output "ERROR: ${_winUsersJson}: user '$_username' references unknown service '$_svcKey'"
                $_svcErrors++
              }
            }
          }
        }
      }
    }
  }
} else {
  Write-Output "Skipping service registry validation (path-scoped mode)."
}

# ---------------------------------------------------------------------------
# 4. Lockfile validation
# ---------------------------------------------------------------------------
Write-Output ("`n=== [{0}] Lockfile validation ===" -f (++$_step))
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
          if ([string]::IsNullOrEmpty($_entry.Value) -or @('CHANGEME') -contains $_entry.Value) {
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
        if ([string]::IsNullOrEmpty($_entry.Value) -or @('CHANGEME') -contains $_entry.Value) {
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
        if ([string]::IsNullOrEmpty($_entry.Value) -or @('CHANGEME') -contains $_entry.Value) {
          Write-Output "ERROR: vscode.$($_entry.Key): placeholder version ($($_entry.Value))"
          $_lfErrors++
        }
      }
    } else {
      Write-Output "WARNING: vscode: empty section (not yet populated)"
    }

    # homebrew: must be non-empty
    if (-not $_lf.ContainsKey('homebrew') -or $_lf.homebrew.Count -eq 0) {
      Write-Output "ERROR: homebrew: empty or missing section"
      $_lfErrors++
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

# ---------------------------------------------------------------------------
# 5. Locked DSC validation
# ---------------------------------------------------------------------------
Write-Output ("`n=== [{0}] Locked DSC validation ===" -f (++$_step))
if (-not $HAS_ARGS) {
  $_dscSystem = Join-Path $RepoRoot 'src\hosts\Windows\system.dsc.yml'
  $_lockfilePath = Join-Path $RepoRoot 'src\lockfiles\lockfile.json'
  $_lfErrors = 0

  # Ensure powershell-yaml module is available.
  if (-not (Get-Module -ListAvailable -Name powershell-yaml)) {
    Write-Output "Installing powershell-yaml module..."
    Install-Module -Name powershell-yaml -Scope CurrentUser -Force -AcceptLicense
  }
  Import-Module -Name powershell-yaml -Force

  # Generate locked DSC in-memory from system.dsc.yml + lockfile.
  $_lockfileData = Get-Content $_lockfilePath -Raw | ConvertFrom-Json -AsHashtable
  $_dscYaml = Get-Content $_dscSystem -Raw
  # Convert YAML → nested hashtable (powershell-yaml may lack -AsHashtable on
  # older versions in CI, requiring manual PSCustomObject → hashtable traversal).
  function _ConvertTo-Hashtable ($_obj) {
    if ($_obj -is [hashtable]) { return $_obj }
    if ($_obj -is [PSCustomObject]) {
      $_ht = [ordered] @{}
      $_obj.PSObject.Properties | ForEach-Object { $_ht[$_.Name] = _ConvertTo-Hashtable $_.Value }
      return $_ht
    }
    if ($_obj -is [array]) { return @($_obj | ForEach-Object { _ConvertTo-Hashtable $_ }) }
    return $_obj
  }
  $_dsc = if ((Get-Command ConvertFrom-Yaml).Parameters.Keys -contains 'AsHashtable') {
    $_dscYaml | ConvertFrom-Yaml -AsHashtable
  } else {
    _ConvertTo-Hashtable ($_dscYaml | ConvertFrom-Yaml)
  }

  foreach ($_resource in $_dsc.properties.resources) {
    if ($_resource.resource -eq 'Microsoft.WinGet.Client/Package' -and $_resource.settings.source -eq 'winget') {
      $_id = $_resource.settings.id
      if ($_lockfileData.winget.ContainsKey($_id) -and $_lockfileData.winget[$_id]) {
        $_resource.settings.version = $_lockfileData.winget[$_id]
      }
    }
  }

  # Validate generated pins match lockfile entries.
  foreach ($_resource in $_dsc.properties.resources) {
    if ($_resource.resource -eq 'Microsoft.WinGet.Client/Package' `
        -and $_resource.settings.source -eq 'winget' `
        -and $_resource.settings.version) {
      $_id = $_resource.settings.id
      $_pinnedVer = $_resource.settings.version
      $_lfVer = if ($_lockfileData.winget.ContainsKey($_id)) { $_lockfileData.winget[$_id] } else { '' }

      if ([string]::IsNullOrEmpty($_lfVer)) {
        Write-Output "ERROR: ${_dscSystem}: $_id has version $_pinnedVer but no lockfile entry"
        $_lfErrors++
      } elseif ($_pinnedVer -ne $_lfVer) {
        Write-Output "ERROR: ${_dscSystem}: $_id pinned $_pinnedVer but lockfile has $_lfVer"
        $_lfErrors++
      }
    }
  }

  # Check for lockfile entries missing version pins in generated output.
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
      Write-Output "ERROR: $_id ($_lfVer) is in lockfile but missing version pin after generation"
      $_lfErrors++
    }
  }

  if ($_lfErrors -gt 0) {
    Write-Output "ERROR: locked DSC validation failed with $_lfErrors error(s)"
    $exitCode = 1
  } else {
    Write-Output 'Locked DSC validation passed'
  }
} else {
  Write-Output 'Skipping locked DSC validation (path-scoped mode).'
}

# ---------------------------------------------------------------------------
# 6. Package manager usage enforcement
# ---------------------------------------------------------------------------
Write-Output ("`n=== [{0}] Package manager usage enforcement ===" -f (++$_step))
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
      -Exclude check.sh,check.ps1 `
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
