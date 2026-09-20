# Test: step 14 repository-policy PS1 enforcement — logging-format scan.
#
# The .sh twin's behavioral tests dot-source the step file and call its policy
# function directly. The PS1 step body cannot be called that way: the runner
# rebuilds it with [scriptblock]::Create($Action.ToString()) inside a runspace,
# so the body is the only thing that exists there. These tests drive the real
# check host instead, with every other step skipped, and assert on what it
# reports.
#
# WHY: both fixture bodies are assembled from [char]96 — a literal backtick-e in
# this file would itself trip the policy under test, since step 14 scans tracked
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

# WHY: only repository-policy runs. The other steps need toolchains (Nix, packer)
# or whole-repo state that a fixture file in a temp directory cannot provide, and
# their findings would drown the scan under test.
$onlySteps = 'repository-policy'

$fixtureDir = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "nucleus-repository-policy-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $fixtureDir -Force > $null

# Invoke-LoggingFormatPolicy — run step 14 over the given files.
# Returns a hashtable with the child's exit code and combined output.
function Invoke-LoggingFormatPolicy {
  param([string[]]$Paths)
  $output = & $pwsh -NoLogo -NoProfile -NonInteractive -File $checkScript --scoped --verbose=repository-policy "--only-steps=$onlySteps" @Paths 2>&1 | Out-String
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
    Assert-Fail 'step 14: a comment naming the automatic Event variable' "exit $($clean.Status); $($clean.Output.Trim())"
  } elseif ($clean.Output -notmatch 'logging format policy passed\.') {
    # WHY: without this the case could pass on a step that never ran instead of a clean scan.
    Assert-Fail 'step 14: a comment naming the automatic Event variable' 'logging format policy did not run'
  } else {
    Assert-Pass 'step 14: a comment naming the automatic Event variable is not an escape'
  }

  # 2. The policy still catches a real escape sequence.
  $violating = Invoke-LoggingFormatPolicy -Paths @($violatingPath)
  if ($violating.Status -eq 0 -or $violating.Output -notmatch 'backtick-e escape literal') {
    Assert-Fail 'step 14: a backtick-e escape sequence' "exit $($violating.Status); $($violating.Output.Trim())"
  } else {
    Assert-Pass 'step 14: a backtick-e escape sequence is reported'
  }
  # 3. The removed skip mechanism list covers the test-harness counter.
  #    The tokens are composed at runtime: step 14 scans tracked .ps1/.sh files,
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
      Assert-Fail 'step 14: a removed skip construct' "exit $($skipScan.Status); $($skipScan.Output.Trim())"
    } else {
      Assert-Pass 'step 14: the test-harness skip counter is reported as a removed skip construct'
    }
  } finally {
    if (Test-Path -LiteralPath $skipLink) { Remove-Item -LiteralPath $skipLink -Force }
    if (Test-Path -LiteralPath $skipFixture) { Remove-Item -LiteralPath $skipFixture -Force }
  }
} finally {
  if (Test-Path -LiteralPath $fixtureDir) {
    Remove-Item -Path $fixtureDir -Recurse -Force
  }
}

Write-Output ''
if ($script:failCount -gt 0) {
  Write-Output "step 14 repository-policy tests: $($script:failCount) failed, $($script:passCount) passed"
  exit 1
}

Write-Output "step 14 repository-policy tests: all $($script:passCount) passed"
exit 0
