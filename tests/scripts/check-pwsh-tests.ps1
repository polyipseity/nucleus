# Regression suite for check-pwsh.ps1 path handling. The defect it pins: a
# repo-relative path was resolved against the caller's working directory, and a
# path that did not resolve was skipped silently, so a file that cannot parse
# reported "syntax check passed".
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\..\src\scripts\lib\pwsh-guard.ps1')
Assert-NucleusPowerShell -Minimum '7.0'

$script:Passed = 0
$script:Failed = 0

function Assert-True {
  param([bool]$Condition, [string]$Name)
  if ($Condition) { $script:Passed += 1; Write-Output "ok $Name" }
  else { $script:Failed += 1; Write-Output "FAIL $Name" }
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$checker = Join-Path $repoRoot 'src\scripts\checks\check-pwsh.ps1'
$broken = Join-Path $repoRoot 'tests\scripts\check-pwsh-fixture-broken.ps1'

Set-Content -LiteralPath $broken -Value 'function Broken {' -Encoding utf8NoBOM
# The fixture is created inside the repo because the defect only shows for a
# repo-relative path. git status reveals it if the test process dies mid-run.
try {
  # A repo-relative path must be found from an unrelated working directory.
  Push-Location -LiteralPath (Join-Path $repoRoot 'src\scripts\checks\check-steps')
  try {
    $relOut = & pwsh -NoProfile -File $checker -OnlyStep Syntax 'tests/scripts/check-pwsh-fixture-broken.ps1' 2>&1
    $relRc = $LASTEXITCODE
  } finally {
    Pop-Location
  }
  $relText = (($relOut | ForEach-Object { "$_" }) -join "`n")
  Assert-True -Condition ($relRc -ne 0 -and $relText -notmatch 'path not found' -and $relText -match 'syntax check failed') -Name 'repo-relative path is checked, not skipped'

  # A path that does not exist is a failure, not a pass.
  $missingOut = & pwsh -NoProfile -File $checker -OnlyStep Syntax 'tests/scripts/does-not-exist.ps1' 2>&1
  $missingRc = $LASTEXITCODE
  Assert-True -Condition ($missingRc -ne 0) -Name 'missing path fails'
  Assert-True -Condition ((($missingOut | ForEach-Object { "$_" }) -join "`n") -match 'does-not-exist\.ps1') -Name 'missing path is named'
} finally {
  if (Test-Path -LiteralPath $broken) { Remove-Item -LiteralPath $broken -Force }
}

Write-Output "$($script:Passed) passed, $($script:Failed) failed"
# WHY: the expected-failure child runs set $LASTEXITCODE; this suite's result is
# its own failure count, not the last native command it happened to invoke.
exit $script:Failed
