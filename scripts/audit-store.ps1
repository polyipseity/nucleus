<#
.SYNOPSIS
  Print Nix store audit baseline metrics (Windows stub).

.DESCRIPTION
  Windows counterpart to scripts/audit-store.sh. Nix store audit is
  POSIX-only (no Nix store on Windows); this stub preserves CLI parity
  and exits successfully after reporting the skip.

.PARAMETER Help
  Show usage.

.EXAMPLE
  .\scripts\audit-store.ps1

.EXAMPLE
  .\scripts\audit-store.ps1 -Help

.NOTES
  Environment variables: NUCLEUS_REPO_ROOT (accepted but unused).
  Exit codes: 0 on success; non-zero on unsupported arguments.
#>
[CmdletBinding()]
param(
  [Alias('h')]
  [switch]$Help
)

$ErrorActionPreference = 'Stop'

$modulePath = Join-Path $PSScriptRoot '..\src\platforms\Windows\modules\Format-NucleusOutput.psm1'
Import-Module $modulePath -Force -DisableNameChecking

$cmd = Get-NucleusCommandName -Path $PSCommandPath

function Show-AuditStoreUsage {
  Write-Output "usage: $cmd.ps1 [--help]"
  Write-Output '  Print Nix store audit baseline metrics (POSIX-only; no-op on Windows).'
}

if ($Help) {
  Show-AuditStoreUsage
  exit 0
}

foreach ($arg in $args) {
  switch ($arg) {
    { $_ -in '-h', '--help' } {
      Show-AuditStoreUsage
      exit 0
    }
    default {
      Write-Error "$cmd`: error: unsupported argument '$arg'"
      Show-AuditStoreUsage
      exit 1
    }
  }
}

Write-Output "$cmd`: Nix store audit is POSIX-only (no Nix store on Windows); skipping."
Write-Output "$cmd`: done"
