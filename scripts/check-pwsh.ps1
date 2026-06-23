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

.PARAMETER SyntaxOnly
  If specified, skip Phase 2 (PSScriptAnalyzer). Used by check.sh for fast
  pre-commit validation; full lint runs in test.sh.

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
#>
[CmdletBinding()]
param(
  [switch]$SyntaxOnly,

  [Parameter(ValueFromRemainingArguments = $true)]
  [string[]]$Paths = @($env:NUCLEUS_CHECK_PATHS -split ';' | Where-Object { $_ })
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $Paths -or $Paths.Count -eq 0) {
  $Paths = @(git ls-files '*.ps1')
}

if (-not $Paths -or $Paths.Count -eq 0) {
  Write-Output 'No PowerShell files to check.'
  exit 0
}

# ---------------------------------------------------------------------------
# Phase 1: Syntax validation via the built-in parser.
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
  Import-Module PSScriptAnalyzer

  $files = @($Paths | Sort-Object -Unique | Where-Object { Test-Path -Path $_ })
  # Split files across parallel Start-Job processes. Each job spawns a separate
  # pwsh process that loads PSScriptAnalyzer from scratch, so cap at 4 to avoid
  # thrashing on module init (especially on high-core-count machines).
  $chunks = [Math]::Min([Environment]::ProcessorCount, 4)
  $size = [Math]::Ceiling($files.Count / $chunks)
  $jobs = for ($i = 0; $i -lt $files.Count; $i += $size) {
    $end = [Math]::Min($i + $size - 1, $files.Count - 1)
    Start-Job -ScriptBlock {
      param($paths)
      Import-Module PSScriptAnalyzer
      $paths | ForEach-Object { Invoke-ScriptAnalyzer -Path $_ -Severity @('Error', 'Warning', 'Information') -ExcludeRule @('PSUseBOMForUnicodeEncodedFile', 'PSUseUsingScopeModifierInNewRunspaces', 'PSReviewUnusedParameter') }
    } -ArgumentList (,$files[$i..$end])
  }
  $null = $jobs | Wait-Job
  $lintResults = $jobs | Receive-Job
  $jobs | Remove-Job

  $nonInfoLints = @($lintResults | Where-Object { $_.Severity -ne 'Information' })

  if ($lintResults.Count -gt 0) {
    $lintResults | ForEach-Object {
      Write-Output ('{0}:{1}:{2}: [{3}] {4}' -f $_.ScriptPath, $_.Line, $_.Column, $_.Severity, $_.Message)
    }
  }

  if ($nonInfoLints.Count -gt 0) {
    throw 'PowerShell lint check failed.'
  }

  Write-Output ("PowerShell lint check passed for {0} files." -f $Paths.Count)
}
