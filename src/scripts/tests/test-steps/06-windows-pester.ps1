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

  # WHY each suite runs in its own child pwsh:
  #   - the runner's session is under Set-StrictMode -Version Latest (scripts/test.ps1)
  #     and Pester test blocks inherit strict mode from their caller, so the suites would
  #     run stricter here than anywhere else — POSIX suites are separate processes and
  #     the step 5 suites run in fresh runspaces;
  #   - process-level state (environment variables, imported modules, globals) must not
  #     carry between suites. That coupling already leaked a fixture repo root into a
  #     concurrent suite and masked failures in CI, and a fresh process cannot.
  # Each child also gets NUCLEUS_REPO_ROOT the way the bash harness provides REPO_ROOT.
  $runnerPath = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "nucleus-pester-runner-$([System.Guid]::NewGuid().ToString('N')).ps1"
  $runnerSource = @'
param([Parameter(Mandatory)][string]$SuitePath)

Import-Module Pester -MinimumVersion 5.0
$result = Invoke-Pester -Path $SuitePath -PassThru -Output None

Write-Output "nucleus-pester result total=$($result.TotalCount) failed=$($result.FailedCount) skipped=$($result.SkippedCount)"
foreach ($failed in $result.Failed) {
  $name = @('ExpandedPath', 'ExpandedName', 'Name') |
    ForEach-Object { $failed.PSObject.Properties[$_].Value } |
    Where-Object { $_ } | Select-Object -First 1
  $record = $failed.PSObject.Properties['ErrorRecord']
  $message = if ($record -and $record.Value) { $record.Value.Exception.Message } else { 'no error record' }
  Write-Output "nucleus-pester failed: $name : $message"
}

if ($result.FailedCount -gt 0) { exit 1 }
exit 0
'@

  Set-Content -Path $runnerPath -Value $runnerSource -Encoding utf8

  function Invoke-PesterSuite {
    param(
      [Parameter(Mandatory)][string]$SuitePath,
      [Parameter(Mandatory)][string]$PwshPath
    )

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $PwshPath
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.Environment['NUCLEUS_REPO_ROOT'] = $RepoRoot
    foreach ($argument in @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', $runnerPath, $SuitePath)) {
      $psi.ArgumentList.Add($argument)
    }

    $process = [System.Diagnostics.Process]::Start($psi)
    # Both streams are read concurrently: the pipes have bounded buffers, so the child
    # would deadlock on a full stdout pipe while stderr drains.
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    $process.WaitForExit()

    $result = $null
    $failures = [System.Collections.Generic.List[string]]::new()
    $noise = [System.Collections.Generic.List[string]]::new()
    foreach ($line in ($stdout.Result -split "`r?`n")) {
      if ($line -match '^nucleus-pester result total=(\d+) failed=(\d+) skipped=(\d+)$') {
        $result = [pscustomobject]@{ Total = [int]$Matches[1]; Failed = [int]$Matches[2]; Skipped = [int]$Matches[3] }
      } elseif ($line -match '^nucleus-pester failed: (.*)$') {
        $failures.Add($Matches[1])
      } elseif ($line.Trim()) {
        $noise.Add($line)
      }
    }

    return [pscustomobject]@{
      ExitCode = $process.ExitCode
      Result   = $result
      Failures = $failures
      Noise    = $noise
      Errors   = $stderr.Result
    }
  }

  # Declared expected skips, per suite. A skip that is not listed here fails the
  # step. Per-suite rather than one repo-wide total, so a skip cannot be moved
  # between suites to keep the count stable.
  #
  # WHY each entry is legitimate: Sync-AgentsSkillManifest resolves the managed
  # skill symlink by its Windows target, which is not meaningful on a POSIX
  # filesystem, so the case is platform-conditional rather than missing.
  $expectedSkips = @{
    'Sync-AgentsSkillManifest.Tests.ps1' = if ($IsWindows) { 0 } else { 1 }
  }

  try {
    $childPwsh = Join-Path -Path $PSHOME -ChildPath 'pwsh'
    if ($IsWindows) { $childPwsh = Join-Path -Path $PSHOME -ChildPath 'pwsh.exe' }

    $totalTests = 0
    $totalFailed = 0
    $totalSkipped = 0
    $failedSuites = [System.Collections.Generic.List[string]]::new()
    foreach ($testFile in $testFiles) {
      $suiteName = [System.IO.Path]::GetFileName($testFile)
      $outcome = Invoke-PesterSuite -SuitePath $testFile -PwshPath $childPwsh

      foreach ($line in $outcome.Noise) { Write-Message $line }
      if ($outcome.Errors.Trim()) { Write-ErrorMessage $outcome.Errors.Trim() }

      if (-not $outcome.Result) {
        # Fail closed: a suite that never reported a result did not run.
        Write-ErrorMessage "Pester: $suiteName reported no result (exit $($outcome.ExitCode))."
        $failedSuites.Add($suiteName)
        continue
      }

      $totalTests += $outcome.Result.Total
      $expected = if ($expectedSkips.ContainsKey($suiteName)) { $expectedSkips[$suiteName] } else { 0 }
      $totalSkipped += $outcome.Result.Skipped
      if ($outcome.Result.Skipped -ne $expected) {
        $failedSuites.Add($suiteName)
        Write-ErrorMessage "Pester: $suiteName skipped $($outcome.Result.Skipped) tests, expected $expected. Declare a legitimate skip in '`$expectedSkips' with a reason, or remove the -Skip."
      } elseif ($outcome.Result.Skipped -gt 0) {
        Write-Message "Pester: $suiteName skipped $($outcome.Result.Skipped) declared test(s)."
      }
      if ($outcome.Result.Failed -gt 0) {
        $totalFailed += $outcome.Result.Failed
        $failedSuites.Add($suiteName)
        Write-ErrorMessage "Pester: $($outcome.Result.Failed) of $($outcome.Result.Total) tests failed in $suiteName."
        foreach ($failure in $outcome.Failures) { Write-ErrorMessage "  $failure" }
      }
    }

    if ($failedSuites.Count -gt 0) {
      Write-ErrorMessage "Pester: $totalFailed of $totalTests tests failed in $($failedSuites.Count) of $($testFiles.Count) suites."
      return $false
    }
    Write-Message "Pester: all $totalTests tests passed in $($testFiles.Count) suites ($totalSkipped declared skip(s))."
    return $true
  } finally {
    Remove-Item -LiteralPath $runnerPath -Force -ErrorAction SilentlyContinue  # check-suppress:suppression_doc: the temp runner is removed on every path; a leftover file after a transient lock must not replace the step's real verdict.
  }
}
