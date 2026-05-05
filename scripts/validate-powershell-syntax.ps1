<#
.SYNOPSIS
  Parse-validates repository PowerShell files.

.DESCRIPTION
  Uses the built-in PowerShell parser (`System.Management.Automation.Language.Parser`)
  to validate `.ps1` syntax without executing scripts. By default the script
  validates every tracked `*.ps1` file in the current Git repository.

  This script is intended to be called via the flake app
  `nix run ./src#validate-powershell-syntax`, which pins runtime dependencies
  (`pwsh`, `git`) to repository-managed versions.

.PARAMETER Paths
  Optional file paths to validate. When omitted, all tracked `*.ps1` files from
  `git ls-files` are validated.

.EXAMPLE
  nix run ./src#validate-powershell-syntax

.EXAMPLE
  nix run ./src#validate-powershell-syntax -- src/hosts/windows/apply.ps1
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
  Write-Host 'No PowerShell files to validate.'
  exit 0
}

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

  throw 'PowerShell syntax validation failed.'
}

Write-Host ("PowerShell syntax validation passed for {0} files." -f $Paths.Count)
