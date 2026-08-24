<#
.SYNOPSIS
  Windows twin of src/scripts/apply.sh: dispatch apply subcommands.

.DESCRIPTION
  Windows-side counterpart to src/scripts/apply.sh.  Dispatches the same
  action vocabulary so `nix run .#apply` behaves identically across
  macOS/NixOS and Windows:
    - health-check: pre-flight disk/connectivity/secret checks.  Not yet
      implemented for Windows; reports and exits 0.
    - audit-store:  Nix store baseline report.  Not yet implemented for
      Windows; reports and exits 0.
    - apply:        full configuration lifecycle.  Handled by the Windows
      host orchestrator (src/hosts/Windows/apply.ps1); not re-implemented
      here.

  This entry point exists for command-surface parity with the POSIX twin and
  is consumed by the Windows host orchestrator for the standalone
  health-check / audit-store actions.

.PARAMETER Action
  The operation to perform: health-check, audit-store, apply.

.PARAMETER RepoRoot
  Repository root.  Auto-derived from the script location when omitted.

.EXAMPLE
  .\scripts\apply.ps1 health-check
  .\scripts\apply.ps1 audit-store

.NOTES
  Environment variables: NUCLEUS_REPO_ROOT.
  Exit codes: 0 on success; non-zero on failure.
#>
[CmdletBinding()]
param(
  [Parameter(Position = 0)]
  [ValidateSet('health-check', 'audit-store', 'apply')]
  [string]$Action = 'apply',

  [string]$RepoRoot = $(if ($env:NUCLEUS_REPO_ROOT) { $env:NUCLEUS_REPO_ROOT } else { '' })
)

$ErrorActionPreference = 'Stop'

$modulePath = Join-Path $PSScriptRoot '..\src\platforms\Windows\modules\Format-NucleusOutput.psm1'
Import-Module $modulePath -Force -DisableNameChecking

if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
  # scripts/apply.ps1 lives at <repo>/scripts/apply.ps1; repo root is the parent.
  $RepoRoot = (Resolve-Path -Path (Join-Path -Path $PSScriptRoot -ChildPath "..")).Path
}

switch ($Action) {
  'health-check' {
    Write-NucleusInfo -CommandName health-check "health-check is not yet implemented for Windows; exiting 0"
    exit 0
  }
  'audit-store' {
    Write-NucleusInfo -CommandName audit-store "audit-store is not yet implemented for Windows; exiting 0"
    exit 0
  }
  'apply' {
    Write-NucleusInfo -CommandName apply "apply is handled by the Windows host orchestrator (src/hosts/Windows/apply.ps1); exiting 0"
    exit 0
  }
}
