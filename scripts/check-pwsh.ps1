<#
.SYNOPSIS
  Parse-validates and lints repository PowerShell files.

.DESCRIPTION
  Phase 1 — Syntax: uses the built-in PowerShell parser
  (`System.Management.Automation.Language.Parser`) to validate `.ps1` syntax
  without executing scripts.

  Phase 2 — Lint: if PSScriptAnalyzer is available in the current session,
  runs `Invoke-ScriptAnalyzer` sequentially in-process at Error and Warning
  severity with excluded rules that trigger false positives.  If the module is
  absent, a warning is printed and the lint phase is skipped so CI can run on
  machines that do not have PSScriptAnalyzer installed (syntax validation
  still passes).

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

  The lint phase uses a grouped execution model via $RuleWorkaroundMap (published
  by src/scripts/shell/optimize-pssa-cache.ps1). Rules not in the map run first
  with no cache manipulation (natural Get-Command population). Rules requiring
  'CachePrePopulation' (e.g., PSAvoidUsingCmdletAliases) run after their
  workaround is applied. This avoids cross-pollution: rules needing real
  CommandInfo metadata never see RemoteCommandInfo dummies.

  The CommandInfoCache pre-population optimization (function
  Initialize-PSScriptAnalyzerCache) triggers PSSA's internal lazy
  initialization and injects lightweight RemoteCommandInfo dummy objects into
  the command cache, avoiding slow Get-Command calls during AvoidAlias
  evaluation. The optimization is non-fatal: if it fails, linting continues
  using the uncached path.

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
    # Initialize-PSScriptAnalyzerCache and $RuleWorkaroundMap).
    . (Join-Path $PSScriptRoot '../src/scripts/shell/optimize-pssa-cache.ps1')

    $settingsFile = Join-Path $PSScriptRoot 'PSScriptAnalyzerSettings.psd1'

    $files = @($Paths | Sort-Object -Unique | Where-Object { Test-Path -Path $_ })

    # Get all rule names and group by workaround.
    # Rules not in $RuleWorkaroundMap get the empty-string key (no workaround).
    $allRuleNames = Get-ScriptAnalyzerRule | ForEach-Object RuleName
    $groups = @{}
    foreach ($rule in $allRuleNames) {
      $wa = if ($RuleWorkaroundMap.ContainsKey($rule)) { $RuleWorkaroundMap[$rule] } else { '' }
      if (-not $groups.ContainsKey($wa)) { $groups[$wa] = [System.Collections.Generic.List[string]]::new() }
      $groups[$wa].Add($rule)
    }

    # Execute groups sequentially: no-workaround first, then workaround groups.
    # Cross-pollution is avoided because CachePrePopulation (dummy injection)
    # runs after all real-CommandInfo population from the no-workaround group.
    $allDiagnostics = [System.Collections.Generic.List[object]]::new()
    $groupOrder = $groups.Keys | Sort-Object
    foreach ($workaround in $groupOrder) {
      $rules = $groups[$workaround]
      if ($workaround -eq 'CachePrePopulation') {
        $null = Initialize-PSScriptAnalyzerCache -Files $files -SettingsFile $settingsFile -Workaround @('CachePrePopulation')
      }
      $groupSettings = @{
        IncludeRules = [string[]]$rules
        Severity = @('Error', 'Warning')
        ExcludeRules = @('PSUseBOMForUnicodeEncodedFile')
        Rules = @{}
      }
      $diags = $files | Invoke-ScriptAnalyzer -Settings $groupSettings
      $allDiagnostics.AddRange($diags)
    }

    # Each rule runs in exactly one group (IncludeRules filters are mutually exclusive),
    # so no rule produces diagnostics in two groups.
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
