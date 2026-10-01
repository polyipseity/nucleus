<#
.SYNOPSIS
  Parse-validates and lints repository PowerShell files.

.DESCRIPTION
  Validates .ps1 syntax with the built-in parser and lints with
  PSScriptAnalyzer. Neither phase executes the scripts.

.PARAMETER Settings
  PSScriptAnalyzerSettings .psd1 controlling enabled rules and severities.
  Defaults to check-PSScriptAnalyzerSettings.psd1, which excludes the slow
  aliases, cmdlet-correctness and ShouldProcess rules plus the auto-fixable
  PSUseBOMForUnicodeEncodedFile. Pass test settings for full coverage:
  -Settings scripts/test-PSScriptAnalyzerSettings.psd1

.PARAMETER OnlyStep
  Run only the named step, `PSSA` (lint; test step 2 leans on it for the
  full-rule pass) or `Syntax` (parser validation). Omit to run both.
  An unknown name is an error.

.PARAMETER Scoped
  With no paths given, skip Git discovery and report nothing to check. Used by
  check.sh/check.ps1 in scoped mode to skip whole-repo discovery.

.PARAMETER Paths
  Paths to check. Omitted, every tracked *.ps1 file is checked.

.EXAMPLE
  nix run ./src#check-pwsh

.EXAMPLE
  nix run ./src#check-pwsh -- -OnlyStep Syntax

.EXAMPLE
  nix run ./src#check-pwsh -- -OnlyStep PSSA -Settings scripts/test-PSScriptAnalyzerSettings.psd1

.EXAMPLE
  nix run ./src#check-pwsh -- -Settings scripts/check-PSScriptAnalyzerSettings.psd1 src/hosts/Windows/apply.ps1

.NOTES
  Environment variables: NUCLEUS_CHECK_PATHS.
  Exit codes: 0 on success; non-zero on failure.
#>
[CmdletBinding()]
param(
  [string]$Settings = '',
  [string[]]$OnlyStep = @(),
  [switch]$Scoped,
  # ValueFromRemainingArguments is required: without it a [string[]] at
  # Position 0 binds the first path and rejects the second, so
  # `check.ps1 pwsh a.ps1 b.ps1` fails on b.ps1. Callers pass whole sets.
  [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
  [string[]]$Paths = @($env:NUCLEUS_CHECK_PATHS -split ';' | Where-Object { $_ })
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = if ($env:NUCLEUS_REPO_ROOT) { $env:NUCLEUS_REPO_ROOT } else { (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path }

if (-not $Settings) { $Settings = Join-Path $RepoRoot 'scripts\check-PSScriptAnalyzerSettings.psd1' }

$modulePath = Join-Path $RepoRoot 'src\platforms\Windows\modules\Format-NucleusOutput.psm1'
Import-Module $modulePath -Force

if (-not $Paths -or $Paths.Count -eq 0) {
  if ($Scoped) {
    Write-NucleusInfo -CommandName check-pwsh 'No PowerShell files to check (scoped mode).'
    exit 0
  }
  $Paths = @(git ls-files '*.ps1' ':(exclude)vendor/')
}

if (-not $Paths -or $Paths.Count -eq 0) {
  Write-NucleusInfo -CommandName check-pwsh 'No PowerShell files to check.'
  exit 0
}

$knownStepNames = [System.Collections.Generic.HashSet[string]]::new(
  [System.StringComparer]::OrdinalIgnoreCase
)
$null = $knownStepNames.Add('PSSA')  # check-suppress:suppression_doc: Add returns collection count, discarded
$null = $knownStepNames.Add('Syntax')  # check-suppress:suppression_doc: Add returns collection count, discarded
$unknownNames = @($OnlyStep | Where-Object { $_ -notin $knownStepNames })
if ($unknownNames.Count -gt 0) {
  throw "Unknown -OnlyStep value(s): $($unknownNames -join ', '). Valid values: $($knownStepNames -join ', ')"
}

$onlyStepSet = [System.Collections.Generic.HashSet[string]]::new(
  [System.StringComparer]::OrdinalIgnoreCase
)
foreach ($t in $OnlyStep) {
    $null = $onlyStepSet.Add($t) }  # check-suppress:suppression_doc: Add returns bool, discarded

# Syntax validation.
$runSyntax = $onlyStepSet.Count -eq 0 -or $onlyStepSet.Contains('Syntax')
if ($runSyntax) {
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
    # WHY: Write-NucleusError → Write-Error is terminating under the script-wide
    # $ErrorActionPreference = 'Stop'; scope Continue so every diagnostic renders
    # before the exit-1 summary (the problems matcher consumes all of them).
    $ErrorActionPreference = 'Continue'
    foreach ($parseError in $parseErrors) {
      Write-NucleusError -CommandName check-pwsh ('{0}:{1}:{2}: {3}' -f $parseError.Extent.File, $parseError.Extent.StartLineNumber, $parseError.Extent.StartColumnNumber, $parseError.Message)
    }
    $ErrorActionPreference = 'Stop'
    Write-NucleusError -CommandName check-pwsh 'PowerShell syntax check failed.'
    exit 1
  }

  Write-NucleusInfo -CommandName check-pwsh ("PowerShell syntax check passed for {0} files." -f $Paths.Count)
}

# PSScriptAnalyzer lint.
$runPssa = $onlyStepSet.Count -eq 0 -or $onlyStepSet.Contains('PSSA')
if ($runPssa) {
  if (-not (Get-Module -ListAvailable -Name PSScriptAnalyzer)) {
    throw 'PSScriptAnalyzer module is required for lint phase. Install with: Install-Module PSScriptAnalyzer -Scope CurrentUser'
  }

  # $env:PSModulePath stays as the running pwsh provides it, which already
  # carries every module directory the enabled rules need.

    Import-Module PSScriptAnalyzer
    # Pre-import PSReadLine to cut the implicit Get-Command overhead PSSA pays per rule.
    Import-Module PSReadLine -ErrorAction SilentlyContinue  # check-suppress:suppression_doc: PSReadLine may be absent in CI/non-interactive shells; this import is a performance optimization, not required

    $settingsFile = $Settings

    $files = @($Paths | Sort-Object -Unique | Where-Object { Test-Path -Path $_ })

    $settingsTable = try { Import-PowerShellDataFile $settingsFile } catch {
      throw "Failed to load PSSA settings from ${settingsFile}: $($_.Exception.Message)"
    }
    $enabledSeverities = [System.Collections.Generic.HashSet[string]]@($settingsTable.Severity)
    $excludedRules = [System.Collections.Generic.HashSet[string]]@($settingsTable.ExcludeRules)
    $allRules = @(Get-ScriptAnalyzerRule)
    if ($allRules.Count -eq 0) {
      throw 'Get-ScriptAnalyzerRule returned no rules — PSScriptAnalyzer may not be installed correctly.'
    }
    $enabledRuleNames = @($allRules | Where-Object {
        $_.RuleName -notin $excludedRules -and $_.Severity -in $enabledSeverities
    } | ForEach-Object RuleName)
    if ($enabledRuleNames.Count -eq 0) {
      throw "No PSSA rules enabled after filtering (severities: $($enabledSeverities -join ', '); excluded: $($excludedRules -join ', '))."
    }

    $diags = $files | Invoke-ScriptAnalyzer -Settings @{
      IncludeRules = [string[]]$enabledRuleNames
      Rules = @{}
    }
    if ($diags) {
      $ErrorActionPreference = 'Continue'
      $diags | ForEach-Object {
        Write-NucleusError -CommandName check-pwsh ('{0}:{1}:{2}: [{3}] {4}' -f $_.ScriptPath, $_.Line, $_.Column, $_.Severity, $_.Message)
      }
      $ErrorActionPreference = 'Stop'
      Write-NucleusError -CommandName check-pwsh 'PowerShell lint check failed.'
      exit 1
    }

    Write-NucleusInfo -CommandName check-pwsh ("PowerShell lint check passed for {0} files." -f $Paths.Count)
}

# The success path must exit explicitly: check.ps1 reads $LASTEXITCODE straight
# after this call, and under Set-StrictMode an unset variable is a terminating
# error, so falling off the end reports a passing run as a failure. The early
# exits above follow the same contract.
exit 0
