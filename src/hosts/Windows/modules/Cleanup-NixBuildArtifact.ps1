<#
.SYNOPSIS
  Remove stale `result` and `result-*` symlinks left by `nix build`,
  `nix run ... -o result`, or `nixos-generators.

.DESCRIPTION
  Scans the repository root for `result` and `result-*` symlinks and removes
  them.  Only removes symlinks — real files or directories are preserved.

.PARAMETER RepoRoot
  Absolute path to the repository root.  Defaults to $env:NUCLEUS_REPO_ROOT
  or auto-detected from the script location.

.PARAMETER WhatIf
  Print actions without executing them.

.PARAMETER PassThru
  Return the number of stale symlinks found instead of logging to stdout.

.OUTPUTS
  None by default.  With -PassThru, returns [int] with the count of removed
  symlinks.

.EXAMPLE
  Clear-NixBuildArtifact -RepoRoot C:\dev\nucleus
  Clear-NixBuildArtifact -WhatIf
#>

function Clear-NixBuildArtifact {
  [CmdletBinding(SupportsShouldProcess = $true)]
  param(
    [Parameter(Mandatory = $false)]
    [string]$RepoRoot = '',

    [Parameter(Mandatory = $false)]
    [switch]$PassThru
  )

  if ([string]::IsNullOrEmpty($RepoRoot)) {
    if ($env:NUCLEUS_REPO_ROOT) {
      $RepoRoot = $env:NUCLEUS_REPO_ROOT
    } else {
      $RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    }
  }

  $_count = 0

  foreach ($_pattern in @('result', 'result-*')) {
    # undoc-supp: probe — Nix build symlinks may not exist; foreach handles empty result.
    $_paths = Get-ChildItem -Path $RepoRoot -Filter $_pattern -Force -ErrorAction SilentlyContinue
    foreach ($_item in $_paths) {
      if ($_item.LinkType -eq 'SymbolicLink') {
        $_target = $_item.Target
        if ($PSCmdlet.ShouldProcess("$_item.FullName -> $_target", 'Remove stale Nix build symlink')) {
          Remove-Item -LiteralPath $_item.FullName -Force
          if (-not $PassThru) {
            Write-Output "cleanup-nix: removed stale Nix build symlink: $($_item.FullName) -> $_target"
          }
          $_count++
        }
      } elseif (-not $PassThru) {
        if ($_item.PSIsContainer -or (-not $_item.LinkType)) {
          Write-Output "cleanup-nix: found non-symlink at $($_item.FullName) — skipping (not a Nix build artifact)"
        }
      }
    }
  }

  if ($PassThru) {
    return $_count
  }

  if ($_count -eq 0) {
    Write-Output 'cleanup-nix: no stale Nix build artifacts found.'
  }
}
