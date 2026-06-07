<#
.SYNOPSIS
  Repository test suite runner (Windows).

.DESCRIPTION
  Currently a placeholder. No Nix-based tests run on Windows.
  Future test steps (Pester, etc.) will be added here.

.EXAMPLE
  pwsh -File scripts/test.ps1

.NOTES
  Exit codes: 0 on success.
#>

Write-Output 'No tests configured for Windows (Nix test suite requires POSIX).'
exit 0
