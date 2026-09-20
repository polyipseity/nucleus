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
  return ($result.FailedCount -eq 0)
}
