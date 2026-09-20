#Requires -Version 7.4
# Gitignore-aware denylist library for PowerShell.
# Provides functions to filter out gitignored paths from file lists.
# Sourced by step-runner.ps1 and check-lib.ps1.

Set-StrictMode -Version Latest

# Select-GitIgnored — reads paths from pipeline input, filters out gitignored paths.
# Uses git check-ignore --stdin for batch-mode efficiency, writing git's stdin
# directly so the byte stream is LF-exact on every platform.
function Select-GitIgnored {
  [CmdletBinding()]
  [OutputType([System.Collections.Generic.List[string]])]
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

    # WHY: git check-ignore --stdin does not strip a trailing CR, so a CRLF
    # byte sequence matches no pattern and the filter silently no-ops. Piping
    # through PowerShell always terminates input with Environment.NewLine, so
    # the paths are written to git's stdin directly, LF-exact.
    $gitCommand = Get-Command -Name 'git' -CommandType Application -ErrorAction Stop |
      Select-Object -First 1

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $gitCommand.Source
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.ArgumentList.Add('check-ignore')
    $psi.ArgumentList.Add('--stdin')

    $process = [System.Diagnostics.Process]::Start($psi)
    # Both streams are read concurrently before stdin is written: the pipes have
    # bounded buffers, so a large path list would deadlock on a full stdout pipe.
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    $process.StandardInput.Write(($allPaths -join "`n") + "`n")
    $process.StandardInput.Close()
    $process.WaitForExit()
    $gitExit = $process.ExitCode

    if ($gitExit -gt 1) {
      # Exit 128: git could not run the query (broken repo, missing index).
      # The documented contract is pass-through, but never silently.
      Write-Warning "Select-GitIgnored: git check-ignore failed (exit $gitExit): $($stderr.Result.Trim())"
      $allPaths
      return
    }

    # Exit 0: at least one path ignored; exit 1: none ignored (empty set).
    $ignoredSet = [System.Collections.Generic.HashSet[string]]::new(
      [System.StringComparer]::OrdinalIgnoreCase)
    foreach ($line in ($stdout.Result -split "`n")) {
      $ignoredPath = $line.TrimEnd("`r")
      if ($ignoredPath) {
        $null = $ignoredSet.Add($ignoredPath)  # check-suppress:suppression_doc: HashSet.Add returns bool; membership is the only effect needed
      }
    }

    if ($ignoredSet.Count -eq 0) {
      $allPaths
      return
    }

    $allPaths | Where-Object { -not $ignoredSet.Contains($_) }
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

  Get-ChildItem -Path $Path -Recurse -Filter $Filter -File | Select-Object -ExpandProperty FullName | Select-GitIgnored
}
