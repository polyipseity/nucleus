<#
.SYNOPSIS
  Repository test suite runner (Windows).

.DESCRIPTION
  Runs PSScriptAnalyzer lint on all PowerShell files.
  No Nix-based tests run on Windows (Nix test suite requires POSIX).

.EXAMPLE
  pwsh -File scripts/test.ps1

.NOTES
  Exit codes: 0 on success; non-zero on failure.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$_step = 0

# ---------------------------------------------------------------------------
# 1. PowerShell lint (PSScriptAnalyzer)
# ---------------------------------------------------------------------------
Write-Output ("`n=== [{0}] PowerShell lint ===" -f (++$_step))
& "$PSScriptRoot\check-pwsh.ps1"

Write-Output ""
Write-Output 'All tests passed.'
