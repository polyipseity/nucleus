# Test: repo-policy-pattern (check step 12) PS1 enforcement for the logging-format scan.
#
# This twin drives the live step 12.
#
# The .sh twin's behavioral tests dot-source the step file and call its policy
# function directly. The PS1 step body cannot be called that way: the runner
# rebuilds it with [scriptblock]::Create($Action.ToString()) inside a runspace,
# so the body is the only thing that exists there. These tests drive the real
# check host instead, with every other step skipped, and assert on what it
# reports.
#
# WHY: both fixture bodies are assembled from [char]96; a literal backtick-e in
# this file would itself trip the policy under test, since the step scans tracked
# .ps1 files and only the shared color helpers are allowlisted.

#Requires -Version 7.4

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:passCount = 0
$script:failCount = 0

function Assert-Pass {
  param([string]$Name)
  Write-Output "PASS $Name"
  $script:passCount++
}

function Assert-Fail {
  param([string]$Name, [string]$Reason)
  Write-Output "FAIL $Name : $Reason"
  $script:failCount++
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
$checkScript = Join-Path $repoRoot 'scripts/check.ps1'
$pwsh = Join-Path -Path $PSHOME -ChildPath $(if ($IsWindows) { 'pwsh.exe' } else { 'pwsh' })

# WHY: only repo-policy-pattern runs. The other steps need toolchains (Nix, packer)
# or whole-repo state that a fixture file in a temp directory cannot provide, and
# their findings would drown the scan under test.
$onlySteps = 'repo-policy-pattern'

$fixtureDir = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "nucleus-repository-policy-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $fixtureDir -Force > $null

# Invoke-LoggingFormatPolicy: run step 12 over the given files.
# Returns a hashtable with the child's exit code and combined output.
function Invoke-LoggingFormatPolicy {
  param([string[]]$Paths, [string]$ScriptPath)
  # WHY: a direct-invocation case needs its own child process, because the stubbed
  # action dot-sources the step file into the child's scope. Routing it through the
  # same function keeps a single exit path for every case in this file.
  if ($ScriptPath) {
    $output = & $pwsh -NoLogo -NoProfile -NonInteractive -File $ScriptPath 2>&1 | Out-String
  } else {
    $output = & $pwsh -NoLogo -NoProfile -NonInteractive -File $checkScript --scoped --verbose=repo-policy-pattern "--only-steps=$onlySteps" @Paths 2>&1 | Out-String
  }
  return @{
    Status = $LASTEXITCODE
    Output = $output
  }
}

try {
  # WHY: -File keeps the host's own flag parsing intact; `& $checkScript` would
  # bind --scoped positionally to the host's first parameter and fail validation.
  $backtick = [char]96
  $cleanPath = Join-Path $fixtureDir 'clean.ps1'
  $violatingPath = Join-Path $fixtureDir 'violating.ps1'

  # A comment that explains why a parameter is named EventName. It mentions the
  # reserved automatic variable, which is not an escape sequence.
  Set-Content -Path $cleanPath -Value @(
    '# WHY: the parameter is EventName because PowerShell reserves ' + $backtick + 'Event as an automatic variable.',
    '$x = 1'
  )
  Set-Content -Path $violatingPath -Value ('$e = "' + $backtick + 'e[31m"')

  # 1. An escape-looking word in a comment is not an escape.
  $clean = Invoke-LoggingFormatPolicy -Paths @($cleanPath)
  if ($clean.Status -ne 0 -or $clean.Output -match 'backtick-e escape literal') {
    Assert-Fail 'step 12: a comment naming the automatic Event variable' "exit $($clean.Status); $($clean.Output.Trim())"
  } elseif ($clean.Output -notmatch 'logging format policy passed\.') {
    # WHY: without this the case could pass on a step that never ran instead of a clean scan.
    Assert-Fail 'step 12: a comment naming the automatic Event variable' 'logging format policy did not run'
  } else {
    Assert-Pass 'step 12: a comment naming the automatic Event variable is not an escape'
  }

  # 2. The policy still catches a real escape sequence.
  $violating = Invoke-LoggingFormatPolicy -Paths @($violatingPath)
  if ($violating.Status -eq 0 -or $violating.Output -notmatch 'backtick-e escape literal') {
    Assert-Fail 'step 12: a backtick-e escape sequence' "exit $($violating.Status); $($violating.Output.Trim())"
  } else {
    Assert-Pass 'step 12: a backtick-e escape sequence is reported'
  }
  # 3. The removed skip mechanism list covers the test-harness counter.
  #    The tokens are composed at runtime: step 12 scans tracked .ps1/.sh files,
  #    this test file included, so a literal token here would be a finding
  #    against the gate's own test. The fixture is a symlink under tests/ (the
  #    scoped skip scan only accepts paths under src/scripts, scripts or tests)
  #    pointing at a file outside the repo, so a killed run leaks a dangling
  #    symlink rather than a gate-violating file in the tree.
  $skipToken = 'assert' + '_skip'
  $counterToken = 'TESTS_' + 'SKIP' + 'PED'
  $skipFixture = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "nucleus-skip-construct-$([guid]::NewGuid().ToString('N')).sh"
  $skipLink = Join-Path $repoRoot 'tests/scripts/removed-skip-construct-fixture.sh'
  Set-Content -Path $skipFixture -Value @("$skipToken case-name case-reason", "echo $counterToken")
  New-Item -ItemType SymbolicLink -Path $skipLink -Target $skipFixture -Force > $null
  try {
    # WHY: the scoped skip scan only accepts repo-relative paths under
    # tests/ (an absolute path fails the prefix test), so run it from the root.
    $skipScan = $null
    Push-Location -LiteralPath $repoRoot
    try {
      $skipScan = Invoke-LoggingFormatPolicy -Paths @('tests/scripts/removed-skip-construct-fixture.sh')
    } finally {
      Pop-Location
    }
    if ($skipScan.Status -eq 0 -or $skipScan.Output -notmatch $skipToken -or $skipScan.Output -notmatch $counterToken) {
      Assert-Fail 'step 12: a removed skip construct' "exit $($skipScan.Status); $($skipScan.Output.Trim())"
    } else {
      Assert-Pass 'step 12: the test-harness skip counter is reported as a removed skip construct'
    }
  } finally {
    if (Test-Path -LiteralPath $skipLink) { Remove-Item -LiteralPath $skipLink -Force }
    if (Test-Path -LiteralPath $skipFixture) { Remove-Item -LiteralPath $skipFixture -Force }
  }

  # 4. envrc ban policy: a root-level .envrc fails with its path reported.
  $envrcPath = Join-Path -Path $fixtureDir -ChildPath '.envrc'
  Set-Content -Path $envrcPath -Value 'use flake'
  $envrcRoot = Invoke-LoggingFormatPolicy -Paths @($envrcPath)
  if ($envrcRoot.Status -eq 0 -or $envrcRoot.Output -notmatch "envrc ban: '[^']*\.envrc' exists; delete it") {
    Assert-Fail 'step 12: a root-level .envrc' "exit $($envrcRoot.Status); $($envrcRoot.Output.Trim())"
  } else {
    Assert-Pass 'step 12: a root-level .envrc is reported'
  }

  # 5. envrc ban policy: a nested .envrc also fails.
  $envrcNestedDir = Join-Path -Path $fixtureDir -ChildPath 'sub'
  New-Item -ItemType Directory -Path $envrcNestedDir -Force > $null
  $envrcNestedPath = Join-Path -Path $envrcNestedDir -ChildPath '.envrc'
  Set-Content -Path $envrcNestedPath -Value 'use flake'
  $envrcNested = Invoke-LoggingFormatPolicy -Paths @($envrcNestedPath)
  if ($envrcNested.Status -eq 0 -or $envrcNested.Output -notmatch "envrc ban: '[^']*\.envrc' exists; delete it") {
    Assert-Fail 'step 12: a nested .envrc' "exit $($envrcNested.Status); $($envrcNested.Output.Trim())"
  } else {
    Assert-Pass 'step 12: a nested .envrc is reported'
  }

  # 6. envrc ban policy: an ordinary file passes with no envrc finding.
  $envrcClean = Invoke-LoggingFormatPolicy -Paths @($cleanPath)
  if ($envrcClean.Status -ne 0 -or $envrcClean.Output -match 'envrc ban:') {
    Assert-Fail 'step 12: a tree without .envrc' "exit $($envrcClean.Status); $($envrcClean.Output.Trim())"
  } elseif ($envrcClean.Output -notmatch 'envrc ban policy passed\.') {
    # WHY: without this the case could pass on a step that never ran.
    Assert-Fail 'step 12: a tree without .envrc' 'envrc ban policy did not run'
  } else {
    Assert-Pass 'step 12: a file without .envrc passes the envrc ban policy'
  }

  # Fixture for case 7 below: an isolated whole-repo subtree, NOT the shared $fixtureDir root.
  #    The root-level, nested, and tree-without cases above leave .envrc files behind, which a whole-repo scan
  #    would also report and make the expected result depend on case ordering.
  #    WHY the src/modules/configs and tests skeleton: the action's preceding scans walk those
  #    paths and the cfg scan dereferences src/modules/configs without an existence guard, so the
  #    fixture root must carry them or the run errors before it reaches the envrc ban under test.
  $envrcWholeRepoRoot = Join-Path -Path $fixtureDir -ChildPath 'whole-repo-root'
  $envrcDecoyDir = Join-Path -Path $envrcWholeRepoRoot -ChildPath 'decoy'
  $envrcGitDecoyDir = Join-Path -Path $envrcDecoyDir -ChildPath '.git'
  $envrcVendorDecoyDir = Join-Path -Path $envrcDecoyDir -ChildPath 'vendor'
  $envrcWholeRepoSkeleton = @(
    $envrcGitDecoyDir
    $envrcVendorDecoyDir
    (Join-Path -Path $envrcWholeRepoRoot -ChildPath 'src/modules/configs')
    (Join-Path -Path $envrcWholeRepoRoot -ChildPath 'tests')
  )
  New-Item -ItemType Directory -Path $envrcWholeRepoSkeleton -Force > $null
  $envrcOffenderDir = Join-Path -Path $envrcWholeRepoRoot -ChildPath 'clean-offender'
  $envrcRealOffender = Join-Path -Path $envrcOffenderDir -ChildPath '.envrc'
  New-Item -ItemType Directory -Path $envrcOffenderDir -Force > $null
  Set-Content -Path $envrcRealOffender -Value 'use flake'
  Set-Content -Path (Join-Path -Path $envrcGitDecoyDir -ChildPath '.envrc') -Value 'use flake'
  Set-Content -Path (Join-Path -Path $envrcVendorDecoyDir -ChildPath '.envrc') -Value 'use flake'

  # 7. envrc ban policy: whole-repo mode reaches the real prune through a direct action invocation.
  #    The harness above cannot cover this: step 12 registers -Platform windows, so the check host
  #    reports it "not applicable (platform: windows)" on macOS and the whole-repo branch never runs.
  #    The child sets the variables check-lib.ps1 needs at dot-source time ($RepoRoot, $FrameworkDir,
  #    $CheckDir), stubs Register-Step to capture the action, dot-sources the step file, and invokes
  #    the action itself: the same single-$Context call the runner makes at step-runner.ps1:593. It
  #    clears NUCLEUS_REPO_ROOT so the step scans the fixture, not the live repo.
  #
  #    The fixture carries one clean offender plus a .git decoy and a vendor decoy under decoy/. Both
  #    decoys must be EXCLUDED by the prune, so only clean-offender/.envrc is reported.
  $envrcWholeRepoScript = Join-Path -Path $fixtureDir -ChildPath 'whole-repo.ps1'
  Set-Content -Path $envrcWholeRepoScript -Value @(
    # WHY: the action's preceding scans surface non-terminating errors (missing git context,
    # empty scans) that are expected for a fixture tree, so they must not abort the run and
    # hide the envrc policy under test; the assertions still gate on its reported output.
    '$ErrorActionPreference = "Continue"',
    # reason: NUCLEUS_REPO_ROOT is expected to be absent, and the whole-repo scan must target the fixture root
    'Remove-Item -Path Env:NUCLEUS_REPO_ROOT -ErrorAction Ignore',
    ('$RepoRoot = ''{0}''' -f $repoRoot),
    '$FrameworkDir = Join-Path $RepoRoot "src/scripts/lib"',
    '$CheckDir = Join-Path $RepoRoot "src/scripts/checks"',
    '. (Join-Path $CheckDir "check-lib.ps1")',
    '. (Join-Path $FrameworkDir "deny-list.ps1")',
    '$script:Captured = $null',
    'function Register-Step { param($Id,$Name,$Platform,$Mode,$Requires,[scriptblock]$Action); $script:Captured = $Action }',
    '. (Join-Path $CheckDir "check-steps/12-repo-policy-pattern.ps1")',
    ('$Context = [pscustomobject]@{{ HasArgs = $false; RepoRoot = ''{0}''; PositionalArgs = @(); NixFiles = @() }}' -f $envrcWholeRepoRoot),
    '$out = @(& $script:Captured $Context 2>&1) | ForEach-Object { $_.ToString() }',
    'foreach ($line in $out) { Write-Output $line }'
  )
  $envrcWholeRepo = Invoke-LoggingFormatPolicy -ScriptPath $envrcWholeRepoScript
  $envrcOffenders = @($envrcWholeRepo.Output -split "`n" | Where-Object { $_ -match "envrc ban: '" })
  $envrcGitReported = @($envrcOffenders | Where-Object { $_ -match 'decoy[/\\]\.git[/\\]\.envrc' }).Count
  $envrcVendorReported = @($envrcOffenders | Where-Object { $_ -match 'decoy[/\\]vendor[/\\]\.envrc' }).Count
  $envrcCleanReported = @($envrcOffenders | Where-Object { $_ -match 'clean-offender[/\\]\.envrc' }).Count
  # WHY: no exit-status guard here. The child discards the action's $false return value, so
  # $LASTEXITCODE reads a native child's code and cannot gate the result. The action's own
  # failure banner is the discriminator that the scan actually failed.
  if ($envrcCleanReported -ne 1 -or $envrcVendorReported -ne 0 -or $envrcGitReported -ne 0) {
    Assert-Fail 'step 12: a whole-repo .envrc scan through a direct action invocation' "exit $($envrcWholeRepo.Status); offenders: $(@($envrcOffenders).Count) -- expected only the clean offender, with the .git and vendor decoys pruned"
  } elseif ($envrcWholeRepo.Output -notmatch 'envrc ban policy check failed with 1 error') {
    Assert-Fail 'step 12: a whole-repo .envrc scan through a direct action invocation' 'the failure summary must count exactly one error'
  } elseif ($envrcWholeRepo.Output -notlike '*repository policy (pattern-based) check failed*') {
    # WHY: the offender counts alone cannot distinguish a scan that found nothing at all,
    # so the failing exit status needs the action's own failure banner as the discriminator.
    Assert-Fail 'step 12: a whole-repo .envrc scan through a direct action invocation' 'the action must report the pattern-based check as failed'
  } else {
    Assert-Pass 'step 12: a whole-repo .envrc scan reports the clean offender and prunes the .git and vendor decoys'
  }

  # 8. envrc ban policy: the tightened nested regex pins the nested path.
  #    The nested case above matches [^\']*\.envrc, which the root-level path also matches, so it
  #    cannot prove the check reports the nested file it was handed. This one requires the sub
  #    segment. HasArgs = $true selects the scoped branch, which skips the whole-repo scans that a
  #    bare fixture root cannot satisfy (the cfg scan needs src/modules/ to exist).
  $envrcTightScript = Join-Path -Path $fixtureDir -ChildPath 'nested-tight.ps1'
  Set-Content -Path $envrcTightScript -Value @(
    # WHY: the action's preceding scans surface non-terminating errors that are expected for a
    # fixture tree, so they must not abort the run before the scoped envrc path is checked; the
    # assertion still gates on that reported path.
    '$ErrorActionPreference = "Continue"',
    # reason: NUCLEUS_REPO_ROOT is expected to be absent, and the scoped path check must read the fixture root
    'Remove-Item -Path Env:NUCLEUS_REPO_ROOT -ErrorAction Ignore',
    ('$RepoRoot = ''{0}''' -f $repoRoot),
    '$FrameworkDir = Join-Path $RepoRoot "src/scripts/lib"',
    '$CheckDir = Join-Path $RepoRoot "src/scripts/checks"',
    '. (Join-Path $CheckDir "check-lib.ps1")',
    '. (Join-Path $FrameworkDir "deny-list.ps1")',
    '$script:Captured = $null',
    'function Register-Step { param($Id,$Name,$Platform,$Mode,$Requires,[scriptblock]$Action); $script:Captured = $Action }',
    '. (Join-Path $CheckDir "check-steps/12-repo-policy-pattern.ps1")',
    ('$Context = [pscustomobject]@{{ HasArgs = $true; RepoRoot = ''{0}''; PositionalArgs = @(''{1}''); NixFiles = @() }}' -f $fixtureDir, $envrcNestedPath),
    '$out = @(& $script:Captured $Context 2>&1) | ForEach-Object { $_.ToString() }',
    'foreach ($line in $out) { Write-Output $line }'
  )
  $envrcNestedTight = Invoke-LoggingFormatPolicy -ScriptPath $envrcTightScript
  # WHY: this gates on the action's own failure banner, not on $Status. The runner turns the
  # action's $false return value into exit 1 (step-runner.ps1:603-604), but this child script
  # discards that return value, so $LASTEXITCODE reads a native child's code and drifts to 0.
  if ($envrcNestedTight.Output -notmatch "envrc ban: '[^']*[/\\]sub[/\\]\.envrc' exists" -or $envrcNestedTight.Output -notlike '*repository policy (pattern-based) check failed*') {
    Assert-Fail 'step 12: a nested .envrc is reported with its nested path' $envrcNestedTight.Output.Trim()
  } else {
    Assert-Pass 'step 12: a nested .envrc is reported with its nested path'
  }
} finally {
  if (Test-Path -LiteralPath $fixtureDir) {
    Remove-Item -Path $fixtureDir -Recurse -Force
  }
}

Write-Output ''
if ($script:failCount -gt 0) {
  Write-Output "step 12 repository-policy tests: $($script:failCount) failed, $($script:passCount) passed"
  exit 1
}

Write-Output "step 12 repository-policy tests: all $($script:passCount) passed"
exit 0
