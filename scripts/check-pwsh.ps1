<#
.SYNOPSIS
  Parse-validates and lints repository PowerShell files.

.DESCRIPTION
  Syntax validation: uses the built-in PowerShell parser
  (`System.Management.Automation.Language.Parser`) to validate `.ps1` syntax
  without executing scripts.

  PSScriptAnalyzer lint: runs `Invoke-ScriptAnalyzer` at Error, Warning, and
  Information severity on all enabled rules.

.PARAMETER Settings
  Path to a PSScriptAnalyzerSettings .psd1 file. Controls which rules and
  severities are enabled. Defaults to PSScriptAnalyzerSettings.check.psd1
  (excludes three slow rules — PSAvoidUsingCmdletAliases,
  PSUseCmdletCorrectly, PSShouldProcess — plus
  PSUseBOMForUnicodeEncodedFile, which is auto-fixable and low value).
  Pass test settings for full coverage:
  -Settings scripts/PSScriptAnalyzerSettings.test.psd1

.PARAMETER SkipStep
  Step names to skip. Recognized values:
  - `PSSA` — skip PSScriptAnalyzer lint (syntax-only; used by check step 2 on pre-commit).
  - `Syntax` — skip parser syntax validation (PSSA-only; used by test step 2 on pre-push).
  Unknown step names cause an error.

.PARAMETER Scoped
  If specified and no paths are given, skip Git discovery (no files to check).
  Used by check.sh/check.ps1 in scoped mode to skip whole-repo discovery.

.PARAMETER Paths
  Optional file paths to check. When omitted, all tracked `*.ps1` files from
  `git ls-files` are checked (default: none; all tracked .ps1 files).

.EXAMPLE
  nix run ./src#check-pwsh

.EXAMPLE
  nix run ./src#check-pwsh -- -SkipStep PSSA

.EXAMPLE
  nix run ./src#check-pwsh -- -SkipStep Syntax -Settings scripts/PSScriptAnalyzerSettings.test.psd1

.EXAMPLE
  nix run ./src#check-pwsh -- -Settings scripts/PSScriptAnalyzerSettings.check.psd1 src/hosts/Windows/apply.ps1

.NOTES
  Environment variables: NUCLEUS_CHECK_PATHS.
  Exit codes: 0 on success; non-zero on failure.
#>
[CmdletBinding()]
param(
  [string]$Settings = (Join-Path $PSScriptRoot 'PSScriptAnalyzerSettings.check.psd1'),
  [string[]]$SkipStep = @(),
  [switch]$Scoped,
  [Parameter(Position = 0)]
  [string[]]$Paths = @($env:NUCLEUS_CHECK_PATHS -split ';' | Where-Object { $_ })
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $Paths -or $Paths.Count -eq 0) {
  if ($Scoped) {
    Write-Output 'No PowerShell files to check (scoped mode).'
    exit 0
  }
  $Paths = @(git ls-files '*.ps1' ':(exclude)vendor/')
}

if (-not $Paths -or $Paths.Count -eq 0) {
  Write-Output 'No PowerShell files to check.'
  exit 0
}

# Validate SkipStep entries against known step names.
$knownStepNames = [System.Collections.Generic.HashSet[string]]::new(
  [System.StringComparer]::OrdinalIgnoreCase
)
$null = $knownStepNames.Add('PSSA')  # check-suppress:suppression_doc: Add returns collection count, discarded
$null = $knownStepNames.Add('Syntax')  # check-suppress:suppression_doc: Add returns collection count, discarded
$unknownNames = @($SkipStep | Where-Object { $_ -notin $knownStepNames })
if ($unknownNames.Count -gt 0) {
  throw "Unknown -SkipStep value(s): $($unknownNames -join ', '). Valid values: $($knownStepNames -join ', ')"
}

$skipStepSet = [System.Collections.Generic.HashSet[string]]::new(
  [System.StringComparer]::OrdinalIgnoreCase
)
foreach ($t in $SkipStep) {
    $null = $skipStepSet.Add($t) }  # check-suppress:suppression_doc: Add returns bool, discarded

# ---------------------------------------------------------------------------
# Syntax validation.
# ---------------------------------------------------------------------------
$skipSyntax = $skipStepSet -contains 'Syntax'
if (-not $skipSyntax) {
  $parseErrors = @($Paths | Sort-Object -Unique | ForEach-Object -Parallel {
    $path = $_
    if (-not (Test-Path -Path $path)) {
      return
    }

    $tokens = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)  # check-suppress:suppression_doc: ParseFile returns AST, discarded; only token/error refs needed

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
} else {
  Write-Output 'PowerShell syntax check skipped (-SkipStep Syntax).'
}

# ---------------------------------------------------------------------------
# PSScriptAnalyzer lint.
# ---------------------------------------------------------------------------
$skipPSSA = $skipStepSet -contains 'PSSA'
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

    $settingsFile = $Settings

    $files = @($Paths | Sort-Object -Unique | Where-Object { Test-Path -Path $_ })

    $settingsTable = Import-PowerShellDataFile $settingsFile
    $enabledSeverities = [System.Collections.Generic.HashSet[string]]@($settingsTable.Severity)
    $excludedRules = [System.Collections.Generic.HashSet[string]]@($settingsTable.ExcludeRules)
    $enabledRuleNames = @(Get-ScriptAnalyzerRule | Where-Object {
        $_.RuleName -notin $excludedRules -and $_.Severity -in $enabledSeverities
    } | ForEach-Object RuleName)

    $diags = $files | Invoke-ScriptAnalyzer -Settings @{
      IncludeRules = [string[]]$enabledRuleNames
      Rules = @{}
    }
    if ($diags) {
      $diags | ForEach-Object {
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
  Write-Output 'PowerShell lint skipped (-SkipStep PSSA).'
}
