<#
.SYNOPSIS
  Parse-validates and lints repository PowerShell files.

.DESCRIPTION
  Syntax validation: uses the built-in PowerShell parser
  (`System.Management.Automation.Language.Parser`) to validate `.ps1` syntax
  without executing scripts.

  PSScriptAnalyzer lint: runs `Invoke-ScriptAnalyzer` at Error and Warning
  severity on enabled rules. Rules execute in two ordered groups to prevent
  cache pollution — all rules except PSAvoidUsingCmdletAliases first (with
  real CommandInfo pre-population), then PSAvoidUsingCmdletAliases last (after
  dummy cache injection).

.PARAMETER SkipTest
  Test names to skip. Initially only 'PSSA' is recognized — bypasses the
  PSScriptAnalyzer lint. Used by check.sh/check.ps1 for fast pre-commit
  validation; test.sh/test.ps1 run without -SkipTest (full lint). Unknown
  names are silently ignored.

.PARAMETER Scoped
  If specified and no paths are given, skip Git discovery (no files to check).
  Used by check.sh/check.ps1 in scoped mode to skip whole-repo discovery.

.PARAMETER Paths
  Optional file paths to check. When omitted, all tracked `*.ps1` files from
  `git ls-files` are checked (default: none; all tracked .ps1 files).

.EXAMPLE
  nix run ./src#check-pwsh

.EXAMPLE
  nix run ./src#check-pwsh -- -SkipTest PSSA

.EXAMPLE
  nix run ./src#check-pwsh -- src/hosts/Windows/apply.ps1

.NOTES
  Environment variables: NUCLEUS_CHECK_PATHS.
  Exit codes: 0 on success; non-zero on failure.

  The lint phase runs rules in two explicit groups:
  1. All rules except PSAvoidUsingCmdletAliases — runs with natural cache
     population (hybrid pre-population injects real CommandInfo objects for
     matched command names first).
  2. PSAvoidUsingCmdletAliases (last) — runs after dummy injection fills all
     remaining cache entries. This avoids cross-pollution: rules needing real
     CommandInfo metadata (Parameters, ParameterSets) never see dummies.
#>
[CmdletBinding()]
param(
  [string[]]$SkipTest = @(),
  [switch]$Scoped,
  [Parameter(ValueFromRemainingArguments = $true)]
  [string[]]$Paths = @($env:NUCLEUS_CHECK_PATHS -split ';' | Where-Object { $_ })
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $Paths -or $Paths.Count -eq 0) {
  if ($Scoped) {
    Write-Output 'No PowerShell files to check (scoped mode).'
    exit 0
  }
  $Paths = @(git ls-files '*.ps1')
}

if (-not $Paths -or $Paths.Count -eq 0) {
  Write-Output 'No PowerShell files to check.'
  exit 0
}

$skipTestSet = [System.Collections.Generic.HashSet[string]]::new(
  [System.StringComparer]::OrdinalIgnoreCase
)
foreach ($t in $SkipTest) { $null = $skipTestSet.Add($t) }

# ---------------------------------------------------------------------------
# Syntax validation.
# ---------------------------------------------------------------------------
$parseErrors = @($Paths | Sort-Object -Unique | ForEach-Object -Parallel {
  $path = $_
  if (-not (Test-Path -Path $path)) {
    return
  }

  $tokens = $null
  $errors = $null
  [void][System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)

  if ($errors) {
    $errors
  }
} -ThrottleLimit ([System.Environment]::ProcessorCount) | Where-Object { $_ -ne $null })

if ($parseErrors.Count -gt 0) {
  foreach ($parseError in $parseErrors) {
    Write-Output ('{0}:{1}:{2}: {3}' -f $parseError.Extent.File, $parseError.Extent.StartLineNumber, $parseError.Extent.StartColumnNumber, $parseError.Message)
  }

  throw 'PowerShell syntax check failed.'
}

Write-Output ("PowerShell syntax check passed for {0} files." -f $Paths.Count)

# ---------------------------------------------------------------------------
# PSScriptAnalyzer lint.
# ---------------------------------------------------------------------------
$skipPSSA = $skipTestSet -contains 'PSSA'
if (-not $skipPSSA) {
  # Preflight: PSScriptAnalyzer is required.
  if (-not (Get-Module -ListAvailable -Name PSScriptAnalyzer)) {
    throw 'PSScriptAnalyzer module is required for lint phase. Install with: Install-Module PSScriptAnalyzer -Scope CurrentUser'
  }

  $originalPSModulePath = $env:PSModulePath
  try {
  # Scope PSModulePath to reduce module-discovery overhead during PSSA rule evaluation.
    $env:PSModulePath = @(
      "$PSHome/Modules"
      [System.IO.Path]::Combine($HOME, '.local/share/powershell/Modules')
    ) -join [System.IO.Path]::PathSeparator

    Import-Module PSScriptAnalyzer
    # Pre-import commonly-used modules to reduce PSSA's implicit Get-Command overhead during rule evaluation.
    Import-Module PSReadLine -ErrorAction SilentlyContinue  # check-suppress:suppression_doc: PSReadLine may be absent in CI/non-interactive shells; this import is a performance optimization, not required

    # Dot-source the CommandInfoCache pre-population helper (provides
    # Initialize-PSScriptAnalyzerCache).
    . (Join-Path $PSScriptRoot '../src/scripts/shell/optimize-pssa-cache.ps1')
    # Dot-source hybrid pre-population helpers (Get-UniqueCommandNames, Get-MatchingRealCommands).
    . (Join-Path $PSScriptRoot '../src/scripts/shell/pssa-cache-hybrid.ps1')

    $settingsFile = Join-Path $PSScriptRoot 'PSScriptAnalyzerSettings.psd1'

    $files = @($Paths | Sort-Object -Unique | Where-Object { Test-Path -Path $_ })

    # Hybrid pre-population — parse all command names from target files
    # and inject real CommandInfo objects for names that match loaded commands.
    # This runs before any Invoke-ScriptAnalyzer call, so the main rules benefit
    # from fast cache hits on real commands.
    $allNames = @(Get-UniqueCommandNames -Files $files)
    if ($allNames.Count -gt 0) {
      $realMap = Get-MatchingRealCommands -CommandNames $allNames
      if ($realMap.Count -gt 0) {
        $null = Initialize-PSScriptAnalyzerCache -Files $files -SettingsFile $settingsFile -RealCommandMap $realMap
      }
    }

    # All enabled rules except PSAvoidUsingCmdletAliases.
    # Must run BEFORE dummy injection. These rules inspect CommandInfo
    # metadata (Parameters, ParameterSets) and would crash on RemoteCommandInfo
    # dummies. The hybrid pre-population real-object injection gives them fast cache hits.
    #
    # Enabled rules come from the settings file: Severity filter + ExcludeRules.
    $allDiagnostics = [System.Collections.Generic.List[object]]::new()
    $settings = Import-PowerShellDataFile $settingsFile
    $enabledSeverities = [System.Collections.Generic.HashSet[string]]@($settings.Severity)
    $excludedRules = [System.Collections.Generic.HashSet[string]]@($settings.ExcludeRules)
    $enabledRuleNames = @(Get-ScriptAnalyzerRule | Where-Object {
        $_.RuleName -notin $excludedRules -and $_.Severity -in $enabledSeverities
    } | ForEach-Object RuleName)
    $phaseCRuleNames = [string[]]@($enabledRuleNames | Where-Object { $_ -ne 'PSAvoidUsingCmdletAliases' })
    $phaseDRuleNames = [string[]]@($enabledRuleNames | Where-Object { $_ -eq 'PSAvoidUsingCmdletAliases' })
    if ($phaseCRuleNames.Count -gt 0) {
      $phaseCSettings = @{
        IncludeRules = $phaseCRuleNames
        Rules = @{}
      }
      $diags = $files | Invoke-ScriptAnalyzer -Settings $phaseCSettings
      $allDiagnostics.AddRange($diags)
    }

    # PSAvoidUsingCmdletAliases (last). This rule's cache hit pattern
    # is existence-only (aliases → commands), so RemoteCommandInfo dummies work.
    # Dummy injection happens here, after all other rules have finished, to
    # prevent cross-pollution of the cache.
    if ($phaseDRuleNames.Count -gt 0 -and $allNames.Count -gt 0) {
      $null = Initialize-PSScriptAnalyzerCache -Files $files -SettingsFile $settingsFile -CommandNames @($allNames) -InjectDummies
      $phaseDSettings = @{
        IncludeRules = $phaseDRuleNames
        Rules = @{}
      }
      $avoidDiags = $files | Invoke-ScriptAnalyzer -Settings $phaseDSettings
      $allDiagnostics.AddRange($avoidDiags)
    }
    if ($allDiagnostics.Count -gt 0) {
      $allDiagnostics | ForEach-Object {
        Write-Output ('{0}:{1}:{2}: [{3}] {4}' -f $_.ScriptPath, $_.Line, $_.Column, $_.Severity, $_.Message)
      }
      throw 'PowerShell lint check failed.'
    }

    Write-Output ("PowerShell lint check passed for {0} files." -f $Paths.Count)
  }
  finally {
    $env:PSModulePath = $originalPSModulePath
  }
} else {
  Write-Output 'PowerShell lint skipped (-SkipTest PSSA).'
}
