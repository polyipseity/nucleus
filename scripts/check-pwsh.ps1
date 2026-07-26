<#
.SYNOPSIS
  Parse-validates and lints repository PowerShell files.

.DESCRIPTION
  Phase 1 — Syntax: uses the built-in PowerShell parser
  (`System.Management.Automation.Language.Parser`) to validate `.ps1` syntax
  without executing scripts.

  Phase 2 — Lint: if PSScriptAnalyzer is available in the current session,
  runs `Invoke-ScriptAnalyzer` in-process at Error and Warning severity with
  excluded rules that trigger false positives. Rules are executed in two
  ordered groups to prevent cache pollution:
  - Group 1 (Phase C): all rules except PSAvoidUsingCmdletAliases — runs with
    natural cache population (real Get-Command objects from Phase B).
  - Group 2 (Phase D): PSAvoidUsingCmdletAliases (last) — runs after dummy
    injection populates all remaining cache entries, giving 100% cache hits.
  If the module is absent, a warning is printed and the lint phase is skipped
  so CI can run on machines without PSScriptAnalyzer (syntax still passes).

  By default the script checks every tracked `*.ps1` file in the current Git
  repository.

  This script is intended to be called via the flake app
  `nix run ./src#check-pwsh`, which pins runtime dependencies (`pwsh`, `git`)
  to repository-managed versions.

.PARAMETER SyntaxOnly
  If specified, skip Phase 2 (PSScriptAnalyzer). Used by check.sh for fast
  pre-commit validation; full lint runs in test.sh.

.PARAMETER Scoped
  If specified and no paths are given, skip Git discovery (no files to check).
  Used by check.sh/check.ps1 in scoped mode to skip whole-repo discovery.

.PARAMETER Paths
  Optional file paths to check. When omitted, all tracked `*.ps1` files from
  `git ls-files` are checked (default: none; all tracked .ps1 files).

.EXAMPLE
  nix run ./src#check-pwsh

.EXAMPLE
  nix run ./src#check-pwsh -- -SyntaxOnly

.EXAMPLE
  nix run ./src#check-pwsh -- src/hosts/Windows/apply.ps1

.NOTES
  Environment variables: NUCLEUS_CHECK_PATHS.
  Exit codes: 0 on success; non-zero on failure.

  The lint phase runs rules in two explicit groups:
  1. All rules except PSAvoidUsingCmdletAliases — runs with natural cache
     population (Phase B injects real CommandInfo objects for matched names).
  2. PSAvoidUsingCmdletAliases (last) — runs after Initialize-PSScriptAnalyzerCache
     -InjectDummies fills all remaining cache entries with RemoteCommandInfo.
     This avoids cross-pollution: rules needing real CommandInfo metadata
     (Parameters, ParameterSets) never see RemoteCommandInfo dummies.

  The CommandInfoCache pre-population optimization (function
  Initialize-PSScriptAnalyzerCache) triggers PSSA's internal lazy
  initialization and injects real CommandInfo objects and/or
  RemoteCommandInfo dummies into the command cache, avoiding slow Get-Command
  calls. The optimization is non-fatal: if it fails, linting continues using
  the uncached path.

  PSModulePath is scoped to the Nix store and user-local modules to reduce
  module-discovery overhead during rule evaluation. This is the dominant
  factor (reduces first-run from ~100s to ~60s).

  Cross-platform parity note:
  This optimization is PowerShell-only (PSScriptAnalyzer runs in-process).
  No cross-platform equivalent exists; the lint phase is pwsh-only.
#>
[CmdletBinding()]
param(
  [switch]$SyntaxOnly,
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

# ---------------------------------------------------------------------------
# Phase 1: Syntax validation via the built-in parser.
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
# Phase 2: PSScriptAnalyzer lint (best-effort).
# ---------------------------------------------------------------------------
if ($SyntaxOnly) {
  Write-Output 'PowerShell lint skipped (-SyntaxOnly).'
} elseif (-not (Get-Module -ListAvailable -Name PSScriptAnalyzer)) {
  Write-Warning 'PSScriptAnalyzer not found; skipping lint phase. Install it with: Install-Module PSScriptAnalyzer'
}
else {
  # Scope PSModulePath to reduce module-discovery overhead during PSSA rule evaluation.
  $originalPSModulePath = $env:PSModulePath
  try {
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

    # Phase B: Hybrid pre-population — parse all command names from target files
    # and inject real CommandInfo objects for names that match loaded commands.
    # This runs before any Invoke-ScriptAnalyzer call, so Phase C rules benefit
    # from fast cache hits on real commands.
    $allNames = @(Get-UniqueCommandNames -Files $files)
    if ($allNames.Count -gt 0) {
      $realMap = Get-MatchingRealCommands -CommandNames $allNames
      if ($realMap.Count -gt 0) {
        $null = Initialize-PSScriptAnalyzerCache -Files $files -SettingsFile $settingsFile -RealCommandMap $realMap
      }
    }

    # Phase C: All rules except PSAvoidUsingCmdletAliases.
    # Must run BEFORE Phase D (dummy injection). These rules inspect CommandInfo
    # metadata (Parameters, ParameterSets) and would crash on RemoteCommandInfo
    # dummies. Phase B's real-object injection gives them fast cache hits.
    $allDiagnostics = [System.Collections.Generic.List[object]]::new()
    $nonAvoidAliasRules = @(Get-ScriptAnalyzerRule | ForEach-Object RuleName | Where-Object { $_ -ne 'PSAvoidUsingCmdletAliases' })
    if ($nonAvoidAliasRules.Count -gt 0) {
      $groupSettings = @{
        IncludeRules = [string[]]$nonAvoidAliasRules
        Severity = @('Error', 'Warning')
        ExcludeRules = @('PSUseBOMForUnicodeEncodedFile')
        Rules = @{}
      }
      $diags = $files | Invoke-ScriptAnalyzer -Settings $groupSettings
      $allDiagnostics.AddRange($diags)
    }

    # Phase D: PSAvoidUsingCmdletAliases (last). This rule's cache hit pattern
    # is existence-only (aliases → commands), so RemoteCommandInfo dummies work.
    # Dummy injection happens here, after all other rules have finished, to
    # prevent cross-pollution of the cache.
    $avoidAliasAvailable = @(Get-ScriptAnalyzerRule | Where-Object RuleName -eq 'PSAvoidUsingCmdletAliases').Count -gt 0
    if ($avoidAliasAvailable -and $allNames.Count -gt 0) {
      $null = Initialize-PSScriptAnalyzerCache -Files $files -SettingsFile $settingsFile -CommandNames @($allNames) -InjectDummies
      $avoidSettings = @{
        IncludeRules = @('PSAvoidUsingCmdletAliases')
        Severity = @('Error', 'Warning')
        ExcludeRules = @('PSUseBOMForUnicodeEncodedFile')
        Rules = @{}
      }
      $avoidDiags = $files | Invoke-ScriptAnalyzer -Settings $avoidSettings
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
}
