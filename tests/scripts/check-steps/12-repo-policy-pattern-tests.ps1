# Test: repo-policy-pattern (check step 12) PS1 enforcement for the logging-format scan.
#
# This twin drives the live step 12.
#
# The .sh twin's behavioral tests dot-source the step file and call its policy
# function directly. The PS1 step body cannot be called that way: the runner
# rebuilds it with [scriptblock]::Create($Action.ToString()) inside a runspace,
# so the body is the only thing that exists there.
#
# This test dot-sources the step file once, captures its registered action, and
# invokes that action directly per case with the appropriate context (repo root,
# scoped paths, and working directory). Running all cases in one process avoids
# spawning a pwsh child per case while preserving the same assertions and
# failure conditions.
#
# WHY: every fixture body is assembled from [char]96; a literal backtick-e in
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

# Load the check libraries and capture the step 12 action once.
$FrameworkDir = Join-Path $repoRoot 'src/scripts/lib'
$CheckDir = Join-Path $repoRoot 'src/scripts/checks'
$RepoRoot = $repoRoot
. (Join-Path $CheckDir 'check-lib.ps1')
. (Join-Path $FrameworkDir 'deny-list.ps1')
$script:CapturedStepAction = $null
function Register-Step {
  param($Id, $Name, $Platform, $Mode, $Requires, [scriptblock]$Action)
  $null = $Id, $Name, $Platform, $Mode, $Requires
  $script:CapturedStepAction = $Action
}
. (Join-Path $CheckDir 'check-steps/12-repo-policy-pattern.ps1')
if ($null -eq $script:CapturedStepAction) {
  throw 'step 12 action was not captured'
}

# Invoke-CapturedStepAction: invoke the captured step 12 action with a context.
# Returns a hashtable with Status (0 on completion, 1 on exception) and Output.
# Each case runs with ErrorActionPreference Continue and optional working
# directory / NUCLEUS_REPO_ROOT isolation, mirroring the previous child scripts.
function Invoke-CapturedStepAction {
  param(
    [hashtable]$ContextValues,
    [string]$PushLocationPath,
    [switch]$ClearNucleusRepoRoot
  )
  $prevEap = $ErrorActionPreference
  $prevLocation = (Get-Location).Path
  $hadNucleusRoot = Test-Path Env:NUCLEUS_REPO_ROOT
  $prevNucleusRoot = if ($hadNucleusRoot) { $env:NUCLEUS_REPO_ROOT } else { $null }
  try {
    $ErrorActionPreference = 'Continue'
    if ($ClearNucleusRepoRoot) {
      Remove-Item -Path Env:NUCLEUS_REPO_ROOT -ErrorAction Ignore
    }
    if ($PushLocationPath) {
      Set-Location -LiteralPath $PushLocationPath
    }
    $Context = [pscustomobject]$ContextValues
    $out = @(& $script:CapturedStepAction $Context *>&1) | ForEach-Object { $_.ToString() }
    return @{ Status = 0; Output = ($out -join "`n") }
  } catch {
    $caught = @($_ | ForEach-Object { $_.ToString() }) -join "`n"
    return @{ Status = 1; Output = $caught }
  } finally {
    Set-Location -LiteralPath $prevLocation
    if ($ClearNucleusRepoRoot) {
      if ($hadNucleusRoot) { $env:NUCLEUS_REPO_ROOT = $prevNucleusRoot } else { Remove-Item -Path Env:NUCLEUS_REPO_ROOT -ErrorAction Ignore }
    }
    $ErrorActionPreference = $prevEap
  }
}

# Invoke-LoggingFormatAction: scoped single-fixture invocation, the same context
# the previous per-case child scripts used.
function Invoke-LoggingFormatAction {
  param([string]$FixturePath)
  return Invoke-CapturedStepAction -ContextValues @{
    HasArgs = $true; RepoRoot = $repoRoot; PositionalArgs = @($FixturePath); NixFiles = @()
  } -ClearNucleusRepoRoot
}

$fixtureDir = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "nucleus-repository-policy-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $fixtureDir -Force > $null

try {
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
  $clean = Invoke-LoggingFormatAction -FixturePath $cleanPath
  if ($clean.Status -ne 0 -or $clean.Output -match 'backtick-e escape literal') {
    Assert-Fail 'step 12: a comment naming the automatic Event variable' "exit $($clean.Status); $($clean.Output.Trim())"
  } elseif ($clean.Output -notmatch 'logging format policy passed\.') {
    # WHY: without this the case could pass on a step that never ran instead of a clean scan.
    Assert-Fail 'step 12: a comment naming the automatic Event variable' 'logging format policy did not run'
  } else {
    Assert-Pass 'step 12: a comment naming the automatic Event variable is not an escape'
  }

  # 2. The policy still catches a real escape sequence.
  $violating = Invoke-LoggingFormatAction -FixturePath $violatingPath
  if ($violating.Output -notmatch ([regex]::Escape($violatingPath) + ':\d+: backtick-e escape literal') -or $violating.Output -notlike '*repository policy (pattern-based) check failed*') {
    Assert-Fail 'step 12: a backtick-e escape sequence' "exit $($violating.Status); $($violating.Output.Trim())"
  } else {
    Assert-Pass 'step 12: a backtick-e escape sequence is reported'
  }
  # 2b. Inline code starting with a lowercase e is not an escape.
  $inlinePath = Join-Path $fixtureDir 'inline.ps1'
  Set-Content -Path $inlinePath -Value @(
    ('# the ' + $backtick + 'enable flag'),
    ('Write-Output ''the ' + $backtick + 'enable flag''')
  )
  $inline = Invoke-LoggingFormatAction -FixturePath $inlinePath
  if ($inline.Output -match 'backtick-e escape literal') {
    Assert-Fail 'step 12: inline code starting with e' $inline.Output.Trim()
  } elseif ($inline.Output -notmatch 'logging format policy passed\.') {
    # WHY: without this the case could pass on a step that never ran instead of a clean scan.
    Assert-Fail 'step 12: inline code starting with e' 'logging format policy did not run'
  } else {
    Assert-Pass 'step 12: inline code starting with e is not an escape'
  }

  # 2c. A backtick-e that ends the line is an escape with no trailing character.
  $tailPath = Join-Path $fixtureDir 'tail.ps1'
  Set-Content -Path $tailPath -Value ('$esc = ' + $backtick + 'e')
  $tail = Invoke-LoggingFormatAction -FixturePath $tailPath
  if ($tail.Output -notmatch 'backtick-e escape literal') {
    Assert-Fail 'step 12: a backtick-e at end of line' $tail.Output.Trim()
  } elseif ($tail.Output -notmatch 'logging format policy check failed') {
    Assert-Fail 'step 12: a backtick-e at end of line' 'the logging format policy must report the fixture as a failure'
  } else {
    Assert-Pass 'step 12: a backtick-e at end of line is reported'
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
    $skipScan = Invoke-CapturedStepAction -ContextValues @{
      HasArgs = $true; RepoRoot = $repoRoot; PositionalArgs = @('tests/scripts/removed-skip-construct-fixture.sh'); NixFiles = @()
    } -PushLocationPath $repoRoot -ClearNucleusRepoRoot
    if ($skipScan.Output -notmatch ("removed-skip-construct-fixture\.sh:\d+: removed skip mechanism '" + $skipToken + "'") -or $skipScan.Output -notmatch ("removed-skip-construct-fixture\.sh:\d+: removed skip mechanism '" + $counterToken + "'") -or $skipScan.Output -notlike '*repository policy (pattern-based) check failed*') {
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
  $envrcRoot = Invoke-LoggingFormatAction -FixturePath $envrcPath
  if ($envrcRoot.Output -notmatch ("envrc ban: '" + [regex]::Escape($envrcPath) + "' exists; delete it") -or $envrcRoot.Output -notlike '*repository policy (pattern-based) check failed*') {
    Assert-Fail 'step 12: a root-level .envrc' "exit $($envrcRoot.Status); $($envrcRoot.Output.Trim())"
  } else {
    Assert-Pass 'step 12: a root-level .envrc is reported'
  }

  # 5. envrc ban policy: a nested .envrc also fails.
  $envrcNestedDir = Join-Path -Path $fixtureDir -ChildPath 'sub'
  New-Item -ItemType Directory -Path $envrcNestedDir -Force > $null
  $envrcNestedPath = Join-Path -Path $envrcNestedDir -ChildPath '.envrc'
  Set-Content -Path $envrcNestedPath -Value 'use flake'
  $envrcNested = Invoke-LoggingFormatAction -FixturePath $envrcNestedPath
  if ($envrcNested.Output -notmatch ("envrc ban: '" + [regex]::Escape($envrcNestedPath) + "' exists; delete it") -or $envrcNested.Output -notlike '*repository policy (pattern-based) check failed*') {
    Assert-Fail 'step 12: a nested .envrc' "exit $($envrcNested.Status); $($envrcNested.Output.Trim())"
  } else {
    Assert-Pass 'step 12: a nested .envrc is reported'
  }

  # 6. envrc ban policy: an ordinary file passes with no envrc finding.
  $envrcClean = Invoke-LoggingFormatAction -FixturePath $cleanPath
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
  #    The action is invoked with the same single-$Context call the runner makes.
  #    NUCLEUS_REPO_ROOT is cleared so the step scans the fixture, not the live repo.
  #
  #    The fixture carries one clean offender plus a .git decoy and a vendor decoy under decoy/. Both
  #    decoys must be EXCLUDED by the prune, so only clean-offender/.envrc is reported.
  $envrcWholeRepo = Invoke-CapturedStepAction -ContextValues @{
    HasArgs = $false; RepoRoot = $envrcWholeRepoRoot; PositionalArgs = @(); NixFiles = @()
  } -ClearNucleusRepoRoot
  $envrcOffenders = @($envrcWholeRepo.Output -split "`n" | Where-Object { $_ -match "envrc ban: '" })
  $envrcGitReported = @($envrcOffenders | Where-Object { $_ -match 'decoy[/\\]\.git[/\\]\.envrc' }).Count
  $envrcVendorReported = @($envrcOffenders | Where-Object { $_ -match 'decoy[/\\]vendor[/\\]\.envrc' }).Count
  $envrcCleanReported = @($envrcOffenders | Where-Object { $_ -match 'clean-offender[/\\]\.envrc' }).Count
  # WHY: no exit-status guard here. The action's own failure banner is the
  # discriminator that the scan actually failed.
  if ($envrcCleanReported -ne 1 -or $envrcVendorReported -ne 0 -or $envrcGitReported -ne 0) {
    Assert-Fail 'step 12: a whole-repo .envrc scan through a direct action invocation' "exit $($envrcWholeRepo.Status); offenders: $(@($envrcOffenders).Count) -- expected only the clean offender, with the .git and vendor decoys pruned"
  } elseif ($envrcWholeRepo.Output -notmatch 'envrc ban policy check failed with 1 error') {
    Assert-Fail 'step 12: a whole-repo .envrc scan through a direct action invocation' 'the failure summary must count exactly one error'
  } elseif ($envrcWholeRepo.Output -notlike '*repository policy (pattern-based) check failed*') {
    # WHY: the offender counts alone cannot distinguish a scan that found nothing at all,
    # so the action's own failure banner is the discriminator.
    Assert-Fail 'step 12: a whole-repo .envrc scan through a direct action invocation' 'the action must report the pattern-based check as failed'
  } else {
    Assert-Pass 'step 12: a whole-repo .envrc scan reports the clean offender and prunes the .git and vendor decoys'
  }

  # 8. envrc ban policy: the tightened nested regex pins the nested path.
  #    The nested case above matches [^\']*\.envrc, which the root-level path also matches, so it
  #    cannot prove the check reports the nested file it was handed. This one requires the sub
  #    segment. HasArgs = $true selects the scoped branch, which skips the whole-repo scans that a
  #    bare fixture root cannot satisfy (the cfg scan needs src/modules/ to exist).
  $envrcNestedTight = Invoke-CapturedStepAction -ContextValues @{
    HasArgs = $true; RepoRoot = $fixtureDir; PositionalArgs = @($envrcNestedPath); NixFiles = @()
  } -ClearNucleusRepoRoot
  # WHY: this gates on the action's own failure banner, not on $Status.
  if ($envrcNestedTight.Output -notmatch "envrc ban: '[^']*[/\\]sub[/\\]\.envrc' exists" -or $envrcNestedTight.Output -notlike '*repository policy (pattern-based) check failed*') {
    Assert-Fail 'step 12: a nested .envrc is reported with its nested path' $envrcNestedTight.Output.Trim()
  } else {
    Assert-Pass 'step 12: a nested .envrc is reported with its nested path'
  }

  # 9. log capture pair policy: a capture directive discarding a stream is reported.
  #    The log-capture scan walks its RepoRoot, never PositionalArgs, so this case
  #    points RepoRoot at an isolated fixture root. The src/modules/configs and tests
  #    skeleton mirrors case 7: the config-method scan dereferences its root before
  #    the log-capture section runs. The violating body is assembled from split
  #    string pieces so this tracked test file never carries a literal the gate's
  #    own log-capture scan would flag against itself.
  $lcpRoot = Join-Path -Path $fixtureDir -ChildPath 'lcp-root'
  New-Item -ItemType Directory -Path @(
    (Join-Path -Path $lcpRoot -ChildPath 'src/modules/configs')
    (Join-Path -Path $lcpRoot -ChildPath 'tests')
    (Join-Path -Path $lcpRoot -ChildPath 'launchd')
  ) -Force > $null
  $lcpCapturePath = Join-Path -Path $lcpRoot -ChildPath 'launchd/capture-point.nix'
  Set-Content -Path $lcpCapturePath -Value @(
    '{',
    ('  Standard' + 'Output = "/dev' + '/null";'),
    ('  Standard' + 'Error = "/dev' + '/null";'),
    '}'
  )
  # WHY the push: Select-GitIgnored passes every path through only outside a git
  # worktree (deny-list.ps1), and the action inherits this location, so the
  # fixture-root scan never queries git about temp paths.
  $lcpViolation = Invoke-CapturedStepAction -ContextValues @{
    HasArgs = $true; RepoRoot = $lcpRoot; PositionalArgs = @(); NixFiles = @()
  } -PushLocationPath $lcpRoot
  $lcpFinding = "log capture pair: 'launchd/capture-point.nix:2' discards a stream to /dev/null; capture stdout.log and stderr.log instead (output-handling.instructions.md)"
  if ($lcpViolation.Output -notmatch [regex]::Escape($lcpFinding) -or $lcpViolation.Output -notlike '*log capture pair policy check failed*') {
    Assert-Fail 'step 12: a capture directive discarding a stream to /dev/null' "exit $($lcpViolation.Status); $($lcpViolation.Output.Trim())"
  } else {
    Assert-Pass 'step 12: a capture directive discarding a stream to /dev/null is reported'
  }

  # 10. activation naming policy: a violating activation entry name is reported.
  #    The nix scan reads its files through the scoped positional list, so this
  #    case points RepoRoot at an isolated fixture root and feeds the entry file
  #    as the one scoped path. The src/modules/configs skeleton mirrors case 9:
  #    the config-method scan dereferences its root before the activation naming
  #    section runs.
  $anRoot = Join-Path -Path $fixtureDir -ChildPath 'an-root'
  New-Item -ItemType Directory -Path (Join-Path -Path $anRoot -ChildPath 'src/modules/configs') -Force > $null
  $anEntryPath = Join-Path -Path $anRoot -ChildPath 'src/modules/an-case.nix'
  Set-Content -Path $anEntryPath -Value 'home.activation.badName = lib.mkIf true { }'
  # WHY the push: Select-GitIgnored passes every path through only outside a git
  # worktree (deny-list.ps1), and the action inherits this location, so the
  # fixture-root scan never queries git about temp paths.
  $anViolation = Invoke-CapturedStepAction -ContextValues @{
    HasArgs = $true; RepoRoot = $anRoot; PositionalArgs = @('src/modules/an-case.nix'); NixFiles = @()
  } -PushLocationPath $anRoot
  $anFinding = "activation name 'badName' at src/modules/an-case.nix:1 is not kebab-case (see .agents/instructions/activation-scripts.instructions.md)"
  if ($anViolation.Output -notmatch [regex]::Escape($anFinding) -or $anViolation.Output -notlike '*activation naming policy check failed*') {
    Assert-Fail 'step 12: an activation entry name that is not kebab-case' "exit $($anViolation.Status); $($anViolation.Output.Trim())"
  } else {
    Assert-Pass 'step 12: an activation entry name that is not kebab-case is reported'
  }

  # 11. config method compliance: a config missing its method annotation is reported.
  #    The config-method scan reads RepoRoot, not the positional list, so this case
  #    points RepoRoot at an isolated fixture root whose src/modules/configs holds
  #    one config and whose src/ file references its basename with no annotation in
  #    the ten-line window.
  $cmRoot = Join-Path -Path $fixtureDir -ChildPath 'cm-root'
  New-Item -ItemType Directory -Path (Join-Path -Path $cmRoot -ChildPath 'src/modules/configs/demo') -Force > $null
  # WHY two configs: the step reads $cfgFiles.Count off the raw Get-ChildItem result, which is a scalar under StrictMode when the tree holds one file, so a single-config fixture errors before the scan and the case would assert on nothing.
  Set-Content -Path (Join-Path -Path $cmRoot -ChildPath 'src/modules/configs/demo/settings.conf') -Value 'managed = true'
  Set-Content -Path (Join-Path -Path $cmRoot -ChildPath 'src/modules/configs/demo/extra.conf') -Value 'managed = true'
  Set-Content -Path (Join-Path -Path $cmRoot -ChildPath 'src/modules/deploy-demo.nix') -Value @(
    '{'
    '  # the reference below deploys the config and carries no method annotation'
    '  deployPath = "settings.conf";'
    '  # check-suppress:config-method: fixture deployment declares the method inline'
    '  extraPath = "extra.conf";'
    '}'
  )
  # WHY the push: Select-GitIgnored passes every path through only outside a git
  # worktree (deny-list.ps1), and the action inherits this location, so the
  # fixture-root scan never queries git about temp paths.
  $cmViolation = Invoke-CapturedStepAction -ContextValues @{
    HasArgs = $true; RepoRoot = $cmRoot; PositionalArgs = @(); NixFiles = @()
  } -PushLocationPath $cmRoot
  $cmFinding = "demo/settings.conf : referenced but no '# check-suppress:config-method' comment found on or before reference lines"
  if ($cmViolation.Output -notmatch [regex]::Escape($cmFinding) -or $cmViolation.Output -notlike '*config method compliance check failed*') {
    Assert-Fail 'step 12: a config missing its method annotation' "exit $($cmViolation.Status); $($cmViolation.Output.Trim())"
  } else {
    Assert-Pass 'step 12: a config missing its method annotation is reported'
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
