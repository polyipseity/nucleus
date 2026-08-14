<#
.SYNOPSIS
  Lint repository shell scripts with ShellCheck (Windows).

.DESCRIPTION
  Windows counterpart to scripts/check-sh.sh. POSIX check-sh.sh runs treefmt
  (ShellCheck via treefmt-nix); this script invokes shellcheck.exe directly
  because treefmt is Nix-only on POSIX hosts.

  Discovers tracked *.sh files via git ls-files (excluding vendor/) or accepts
  explicit paths. Flags match src/modules/lib/script-tree.nix: -x -S style.

.PARAMETER Scoped
  When set and no paths are given, skip whole-repo discovery.

.PARAMETER Paths
  Optional shell script paths to check.

.NOTES
  Requires ShellCheck.ShellCheck (WinGet) on PATH. Environment: NUCLEUS_CHECK_PATHS.
  Exit codes: 0 on success; non-zero on failure.
#>
[CmdletBinding()]
param(
  [switch]$Scoped,
  [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
  [string[]]$Paths = @($env:NUCLEUS_CHECK_PATHS -split ';' | Where-Object { $_ })
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$modulePath = Join-Path $PSScriptRoot '..\src\platforms\Windows\modules\Format-NucleusOutput.psm1'
Import-Module $modulePath -Force

# check-suppress:suppression_doc: probe whether shellcheck is installed; $null check below throws if absent.
$shellcheck = Get-Command -Name 'shellcheck' -ErrorAction SilentlyContinue
if (-not $shellcheck) {
  throw 'shellcheck is required but was not found in PATH (install ShellCheck.ShellCheck via WinGet)'
}

$repoRoot = if ($env:NUCLEUS_REPO_ROOT) { $env:NUCLEUS_REPO_ROOT } else { Split-Path -Parent $PSScriptRoot }
Push-Location $repoRoot
try {
  if ($Paths.Count -eq 0) {
    if ($Scoped) {
      Write-NucleusInfo -CommandName check-sh 'no shell scripts to check (scoped mode).'
      exit 0
    }
    $Paths = @(git ls-files '*.sh' ':(exclude)vendor/')
  }

  if ($Paths.Count -eq 0) {
    Write-NucleusInfo -CommandName check-sh 'no shell scripts to check.'
    exit 0
  }

  $exitCode = 0
  foreach ($path in $Paths) {
    # --source-path=<script dir> mirrors treefmt.nix's source-path = "SCRIPTDIR":
    # lets shellcheck resolve `# shellcheck source=` directives relative to each script's own directory.
    & $shellcheck.Source -x --source-path="$(Split-Path -Parent $path)" -S style $path
    if ($LASTEXITCODE -ne 0) {
      $exitCode = $LASTEXITCODE
    }
  }

  if ($exitCode -ne 0) {
    exit $exitCode
  }

  Write-NucleusInfo -CommandName check-sh "shell script check passed for $($Paths.Count) files."
}
finally {
  Pop-Location
}
