Register-Step -Id "script-and-framework-tests" -Name "Script and framework tests" -Action {
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
      $null = $seen.Add($match.FullName)  # check-suppress:suppression_doc: HashSet.Add returns bool; seen-membership is the only effect needed.
    }
  }

  foreach ($testFile in $allTests) {
    if ($excludeNames -contains $testFile.BaseName) { continue }
    if ($seen.Contains($testFile.FullName)) { continue }
    $ordered.Add($testFile.FullName)
  }

  $prioritySet = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::OrdinalIgnoreCase)
  foreach ($priority in $priorityNames) {
    $null = $prioritySet.Add($priority)  # check-suppress:suppression_doc: HashSet.Add returns bool; dedupe is the only effect needed.
  }

  $priorityScripts = [System.Collections.Generic.List[string]]::new()
  $parallelScripts = [System.Collections.Generic.List[string]]::new()

  foreach ($testScript in $ordered) {
    $base = [System.IO.Path]::GetFileNameWithoutExtension($testScript)
    if ($prioritySet.Contains($base)) {
      $priorityScripts.Add($testScript)
    } else {
      $parallelScripts.Add($testScript)
    }
  }

  Write-Message '--- discovered script tests ---'

  foreach ($testScript in $priorityScripts) {
    Write-Message "running $([System.IO.Path]::GetFileName($testScript))"
    & $testScript
    if ($LASTEXITCODE -ne 0) { $exitCode = 1 }
  }

  if ($parallelScripts.Count -gt 0) {
    $captureDir = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ([System.Guid]::NewGuid().ToString())
    New-Item -ItemType Directory -Path $captureDir -Force > $null
    $throttle = if ($env:PARALLEL_JOBS) { [int]$env:PARALLEL_JOBS } else { [System.Environment]::ProcessorCount }

    foreach ($testScript in $parallelScripts) {
      Write-Message "running $([System.IO.Path]::GetFileName($testScript))"
    }

    $parallelScripts | ForEach-Object -Parallel {
      $script = $_
      $captureDir = $using:captureDir
      $base = [System.IO.Path]::GetFileName($script)
      $captureFile = Join-Path -Path $captureDir -ChildPath "$base.out"
      & $script *> $captureFile
      if ($LASTEXITCODE -ne 0) {
        New-Item -ItemType File -Path (Join-Path -Path $captureDir -ChildPath "$base.failed") -Force > $null
      }
    } -ThrottleLimit $throttle

    foreach ($testScript in $parallelScripts) {
      $base = [System.IO.Path]::GetFileName($testScript)
      $captureFile = Join-Path -Path $captureDir -ChildPath "$base.out"
      if (Test-Path -LiteralPath $captureFile) {
        Get-Content -LiteralPath $captureFile
      }
    }

    # check-suppress:suppression_doc: capture dir may hold no .failed markers; empty result is the expected pass.
    $failed = @(Get-ChildItem -Path $captureDir -Filter '*.failed' -File -ErrorAction SilentlyContinue)
    if ($failed.Count -gt 0) {
      Write-ErrorMessage 'FAILED script tests:'
      foreach ($marker in $failed) {
        $failedBase = $marker.Name -replace '\.failed$',''
        foreach ($testScript in $parallelScripts) {
          if ([System.IO.Path]::GetFileName($testScript) -eq $failedBase) {
            Write-ErrorMessage $testScript
          }
        }
      }
      $exitCode = 1
    }

    Remove-Item -LiteralPath $captureDir -Recurse -Force
  }

  return ($exitCode -eq 0)
}
