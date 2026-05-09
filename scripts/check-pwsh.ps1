<#
.SYNOPSIS
  Parse-validates and lints repository PowerShell files.

.DESCRIPTION
  Phase 1 — Syntax: uses the built-in PowerShell parser
  (`System.Management.Automation.Language.Parser`) to validate `.ps1` syntax
  without executing scripts.

  Phase 2 — Lint: if PSScriptAnalyzer is available in the current session,
  runs `Invoke-ScriptAnalyzer` at Error and Warning severity.  If the module
  is absent, a warning is printed and the lint phase is skipped so CI can run
  on machines that do not have PSScriptAnalyzer installed (syntax validation
  still passes).

  By default the script checks every tracked `*.ps1` file in the current Git
  repository.

  This script is intended to be called via the flake app
  `nix run ./src#check-pwsh`, which pins runtime dependencies (`pwsh`, `git`)
  to repository-managed versions.

.PARAMETER Paths
  Optional file paths to check. When omitted, all tracked `*.ps1` files from
  `git ls-files` are checked.

.EXAMPLE
  nix run ./src#check-pwsh

.EXAMPLE
  nix run ./src#check-pwsh -- src/hosts/windows/apply.ps1
#>
[CmdletBinding()]
param(
  [Parameter(ValueFromRemainingArguments = $true)]
  [string[]]$Paths
)

$ErrorActionPreference = 'Stop'

if (-not $Paths -or $Paths.Count -eq 0) {
  $Paths = @(git ls-files '*.ps1')
}

if (-not $Paths -or $Paths.Count -eq 0) {
  Write-Host 'No PowerShell files to check.'
  exit 0
}

# ---------------------------------------------------------------------------
# Phase 1: Syntax validation via the built-in parser.
# Parser.ParseFile never executes the script; it only builds an AST and
# collects parse errors, so this phase is safe to run in any environment.
# ---------------------------------------------------------------------------
$parseErrors = @()

foreach ($path in $Paths | Sort-Object -Unique) {
  if (-not (Test-Path -Path $path)) {
    continue
  }

  $tokens = $null
  $errors = $null
  [void][System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)

  if ($errors) {
    $parseErrors += $errors
  }
}

if ($parseErrors.Count -gt 0) {
  foreach ($parseError in $parseErrors) {
    Write-Host ('{0}:{1}:{2}: {3}' -f $parseError.Extent.File, $parseError.Extent.StartLineNumber, $parseError.Extent.StartColumnNumber, $parseError.Message)
  }

  throw 'PowerShell syntax check failed.'
}

Write-Host ("PowerShell syntax check passed for {0} files." -f $Paths.Count)

# ---------------------------------------------------------------------------
# Phase 2: PSScriptAnalyzer lint (best-effort).
# PSScriptAnalyzer is not in nixpkgs; if it is absent the lint phase is
# skipped so CI is not blocked on machines that lack the module.  Syntax
# validation in Phase 1 always runs regardless of PSScriptAnalyzer availability.
# ---------------------------------------------------------------------------
if (-not (Get-Module -ListAvailable -Name PSScriptAnalyzer)) {
  Write-Warning 'PSScriptAnalyzer not found; skipping lint phase. Install it with: Install-Module PSScriptAnalyzer'
}
else {
  Import-Module PSScriptAnalyzer

  $lintResults = @()
  foreach ($path in $Paths | Sort-Object -Unique) {
    if (-not (Test-Path -Path $path)) {
      continue
    }
    $lintResults += Invoke-ScriptAnalyzer -Path $path -Severity @('Error', 'Warning')
  }

  if ($lintResults.Count -gt 0) {
    $lintResults | ForEach-Object {
      Write-Host ('{0}:{1}:{2}: [{3}] {4}' -f $_.ScriptPath, $_.Line, $_.Column, $_.Severity, $_.Message)
    }
    throw 'PowerShell lint check failed.'
  }

  Write-Host ("PowerShell lint check passed for {0} files." -f $Paths.Count)
}
