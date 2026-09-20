Register-Step -Id "windows-pester" -Name "Windows Pester tests" -Platform windows -Action {
  param([Parameter(Mandatory)][PSObject]$Context)

  # These Pester suites exercise Windows-only behavior (Windows service dispatch,
  # DSC wiring, etc.). -Platform windows keeps the step off other hosts, where
  # $PSScriptRoot-relative module loading breaks inside a step-runner runspace.
  $RepoRoot = $Context.RepoRoot

  $windowsTestRoots = @(
    (Join-Path $RepoRoot 'tests\platforms\Windows')
    (Join-Path $RepoRoot 'tests\hosts\Windows')
  )
  $testFiles = @(
    foreach ($root in $windowsTestRoots) {
      if (Test-Path $root) {
        Get-ChildItem -Path $root -Recurse -File |
          Where-Object { $_.Name -like '*.Tests.ps1' -or $_.Name -like '*.tests.ps1' } |
          ForEach-Object { $_.FullName }
      }
    }
  )

  if ($testFiles.Count -eq 0) {
    Write-Message '0 Pester test files found — nothing to run.'
    return $true
  }

  $result = Invoke-Pester -Path $testFiles -PassThru
  if ($result.FailedCount -gt 0) {
    # WHY: -PassThru returns a result object, so a bare exit status discards which
    # tests failed. Report them here or a Windows-only failure is undiagnosable
    # from the CI log.
    Write-ErrorMessage "Pester: $($result.FailedCount) of $($result.TotalCount) tests failed."
    try {
      foreach ($failed in $result.Failed) {
        $name = @('ExpandedPath', 'ExpandedName', 'Name') |
          ForEach-Object { $failed.PSObject.Properties[$_].Value } |
          Where-Object { $_ } | Select-Object -First 1
        $record = $failed.PSObject.Properties['ErrorRecord']
        $message = if ($record -and $record.Value) { $record.Value.Exception.Message } else { 'no error record' }
        Write-ErrorMessage "  $name : $message"
      }
    } catch {
      Write-ErrorMessage "  (could not enumerate failing tests: $($_.Exception.Message))"
    }
    return $false
  }
  Write-Message "Pester: all $($result.TotalCount) tests passed."
  return $true
}
