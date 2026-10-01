#Requires -Version 7.4
# Gitignore-aware denylist library for PowerShell.
# Sourced by step-runner.ps1 and check-lib.ps1.

Set-StrictMode -Version Latest

# WHY: git check-ignore --stdin does not strip a trailing CR, so a CRLF byte
# sequence matches no pattern and the filter silently no-ops. Piping through
# PowerShell always terminates input with Environment.NewLine, so the paths are
# written to git's stdin directly, LF-exact.
function Invoke-GitCheckIgnore {
  [CmdletBinding()]
  [OutputType([PSCustomObject])]
  param(
    [Parameter(Mandatory)]
    [string]$GitExecutable,

    [Parameter(Mandatory)]
    [string[]]$Path
  )

  $psi = [System.Diagnostics.ProcessStartInfo]::new()
  $psi.FileName = $GitExecutable
  $psi.UseShellExecute = $false
  $psi.RedirectStandardInput = $true
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.ArgumentList.Add('check-ignore')
  $psi.ArgumentList.Add('--stdin')

  $process = [System.Diagnostics.Process]::Start($psi)
  # WHY: both streams are read before stdin is written, because the pipes have
  # bounded buffers and a large path list would deadlock on a full stdout pipe.
  $stdout = $process.StandardOutput.ReadToEndAsync()
  $stderr = $process.StandardError.ReadToEndAsync()
  $process.StandardInput.Write(($Path -join "`n") + "`n")
  $process.StandardInput.Close()
  $process.WaitForExit()

  [PSCustomObject]@{
    ExitCode       = $process.ExitCode
    StandardOutput = $stdout.Result
    StandardError  = $stderr.Result
  }
}

# filters pipeline paths through git check-ignore --stdin in batch mode.
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

    # Outside a repo every path passes through
    if (-not (Test-Path '.git') -and -not $env:GIT_DIR) {
      $allPaths
      return
    }

    $gitCommand = Get-Command -Name 'git' -CommandType Application -ErrorAction Stop |
      Select-Object -First 1

    # WHY: git check-ignore --stdin answers 128 for the WHOLE batch when any
    # pathspec lies beyond a symlink, so one such path would disarm the filter for
    # every other path in the call. The paths git names are dropped and the query
    # repeats; a dropped path carries no ignore status, and the file it shadows is
    # enumerated at its real path, so it leaves the result. A round that names
    # nothing this batch actually holds is a plain failure, and that is what keeps
    # the loop finite.
    $pending = [System.Collections.Generic.List[string]]::new()
    foreach ($candidate in $allPaths) { $pending.Add($candidate) }
    $skipped = [System.Collections.Generic.List[string]]::new()
    $ignoredSet = $null

    while ($true) {
      $query = Invoke-GitCheckIgnore -GitExecutable $gitCommand.Source -Path $pending
      if ($query.ExitCode -le 1) {
        # Exit 0 or 1: exit 1 is an empty ignored set, not a failure.
        $ignoredSet = [System.Collections.Generic.HashSet[string]]::new(
          [System.StringComparer]::OrdinalIgnoreCase)
        foreach ($line in ($query.StandardOutput -split "`n")) {
          $ignoredPath = $line.TrimEnd("`r")
          if ($ignoredPath) {
            $null = $ignoredSet.Add($ignoredPath)  # check-suppress:suppression_doc: HashSet.Add returns bool; membership is the only effect needed
          }
        }
        break
      }

      $beyond = @([regex]::Matches($query.StandardError, "pathspec '(.+?)' is beyond a symbolic link") |
        ForEach-Object { $_.Groups[1].Value } |
        Where-Object { $pending.Contains($_) })
      if ($beyond.Count -eq 0) {
        # Exit 128 with no resolvable pathspec: a broken repo or a missing index.
        # The contract is pass-through, but never silently.
        Write-Warning "Select-GitIgnored: git check-ignore failed (exit $($query.ExitCode)): $($query.StandardError.Trim())"
        $allPaths
        return
      }

      foreach ($beyondPath in $beyond) {
        $null = $pending.Remove($beyondPath)  # check-suppress:suppression_doc: List.Remove returns bool; the path leaves the retry batch either way
        $skipped.Add($beyondPath)
      }
    }

    if ($skipped.Count -gt 0) {
      Write-Warning "Select-GitIgnored: dropped $($skipped.Count) path(s) git cannot resolve past a symlink: $($skipped -join ', ')"
    }

    if ($ignoredSet.Count -eq 0) {
      $pending
      return
    }

    $pending | Where-Object { -not $ignoredSet.Contains($_) }
  }
}

# resolves a glob to tracked files, minus gitignored ones.
function Get-GitTrackedFile {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [string]$Filter,
    [string]$Path = '.'
  )

  Get-ChildItem -Path $Path -Recurse -Filter $Filter -File | Select-Object -ExpandProperty FullName | Select-GitIgnored
}
