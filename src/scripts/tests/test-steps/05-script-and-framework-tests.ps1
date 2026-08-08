Register-Step -Id "script-and-framework-tests" -Number 5 -Name "Script and framework tests" -Action {
  param($RepoRoot)

  $exitCode = 0
  $testDir = Join-Path -Path $RepoRoot -ChildPath 'tests' -AdditionalChildPath 'scripts'

  $priorityNames = @('step-runner-unit-tests', 'test-lib-unit-tests', 'deny-list-tests')
  $excludeNames = @('nix-test-eval-tests', 'check-pwsh-tests')

  $allTests = @(Get-ChildItem -Path $testDir -Recurse -Filter '*-tests.ps1' -File |
    Sort-Object -Property FullName)

  $ordered = [System.Collections.Generic.List[string]]::new()
  $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

  foreach ($priority in $priorityNames) {
    $match = $allTests | Where-Object { $_.BaseName -eq $priority } | Select-Object -First 1
    if ($match) {
      $ordered.Add($match.FullName)
      $null = $seen.Add($match.FullName)
    }
  }

  foreach ($testFile in $allTests) {
    if ($excludeNames -contains $testFile.BaseName) { continue }
    if ($seen.Contains($testFile.FullName)) { continue }
    $ordered.Add($testFile.FullName)
  }

  Write-Message '--- discovered script tests ---'
  foreach ($testScript in $ordered) {
    Write-Message "running $([System.IO.Path]::GetFileName($testScript))"
    & $testScript
    if ($LASTEXITCODE -ne 0) { $exitCode = 1 }
  }

  return ($exitCode -eq 0)
}
