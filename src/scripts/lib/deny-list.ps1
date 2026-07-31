#Requires -Version 7.4
# Gitignore-aware denylist library for PowerShell.
# Provides functions to filter out gitignored paths from file lists.
# Sourced by step-runner.ps1 and check-lib.ps1.

Set-StrictMode -Version Latest

# Filter-GitIgnored — reads paths from pipeline input, filters out gitignored paths.
# Uses git check-ignore --stdin for batch-mode efficiency with proper
# $LASTEXITCODE handling (pipefail-safe).
function Filter-GitIgnored {
  [CmdletBinding()]
  param(
    [Parameter(ValueFromPipeline)]
    [string]$Path
  )

  begin {
    $allPaths = [System.Collections.Generic.List[string]]::new()
  }

  process {
    if ($Path) {
      $allPaths.Add($Path)
    }
  }

  end {
    if ($allPaths.Count -eq 0) { return }

    # If not in a git repo, pass through everything
    if (-not (Test-Path '.git') -and -not $env:GIT_DIR) {
      $allPaths
      return
    }

    $tmp = [System.IO.Path]::GetTempFileName()
    try {
      $allPaths | Set-Content -Path $tmp -Encoding utf8NoBOM

      # Capture git check-ignore output and exit code.
      # Using cmd /c to avoid PowerShell's own error handling interfering.
      $ignored = & git check-ignore --stdin 2>$null < $tmp
      $gitExit = $LASTEXITCODE

      if ($gitExit -le 1) {
        # Exit 0: some paths ignored; Exit 1: nothing ignored
        if ($ignored) {
          $ignoredSet = [System.Collections.Generic.HashSet[string]]::new(
            [string[]]@($ignored), [StringComparer]::OrdinalIgnoreCase)
          $allPaths | Where-Object { -not $ignoredSet.Contains($_) }
        } else {
          # Nothing ignored — pass through
          $allPaths
        }
      } else {
        # git error (exit 128) — pass through unchanged
        $allPaths
      }
    } finally {
      Remove-Item -Path $tmp -Force -ErrorAction SilentlyContinue
    }
  }
}

# Get-GitTrackedFile — finds files matching a glob pattern and filters out gitignored ones.
function Get-GitTrackedFile {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [string]$Filter,
    [string]$Path = '.'
  )

  Get-ChildItem -Path $Path -Recurse -Filter $Filter -File | Select-Object -ExpandProperty FullName | Filter-GitIgnored
}
