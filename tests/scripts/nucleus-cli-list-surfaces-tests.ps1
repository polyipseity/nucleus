# D4: list surfaces for nucleus CLI dynamic providers (Windows twins, parse/smoke checks).

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Split-Path -Parent (Split-Path -Parent $scriptDir)
$passed = 0
$failed = 0

function Assert-True([bool]$cond, [string]$name, [string]$detail = '') {
  if ($cond) {
    Write-Output "✓ $name"
    $script:passed++
  } else {
    if ($detail) { Write-Output "✗ ${name}: $detail" } else { Write-Output "✗ $name" }
    $script:failed++
  }
}

Write-Output "`n=== [1] config list --json ==="
$configJson = & pwsh -NoProfile -File (Join-Path $repoRoot 'scripts/config.ps1') list --json 2>$null
$cfgOk = $false
$cfgDetail = ''
try {
  $obj = $configJson | ConvertFrom-Json -AsHashtable
  $cfgOk = $obj.ContainsKey('applyHistoryLimit') -and $obj.ContainsKey('camilladsp.enable')
} catch {
  $cfgDetail = "parse failed: $($_.Exception.Message)"
}
Assert-True -cond $cfgOk -name 'config.ps1 list --json emits dotted-key object' -detail $cfgDetail

Write-Output "`n=== [2] check/test --list-steps ==="
$checkSteps = @(& pwsh -NoProfile -File (Join-Path $repoRoot 'scripts/check.ps1') -ListSteps 2>$null)
Assert-True -cond ($checkSteps -contains 'code-formatting' -and $checkSteps -contains 'app-registry' -and $checkSteps -notcontains 'nix-flake-eval') -name 'check.ps1 -ListSteps prints Windows check step IDs'

$testSteps = @(& pwsh -NoProfile -File (Join-Path $repoRoot 'scripts/test.ps1') --list-steps 2>$null)
Assert-True -cond ($testSteps -contains 'nix-tests' -and $testSteps -contains 'windows-pester') -name 'test.ps1 --list-steps prints Windows test step IDs'

Write-Output "`n=== [3] logs --list-logs ==="
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("nucleus-logs-list-" + [Guid]::NewGuid().ToString('n'))
New-Item -ItemType Directory -Path $tmp -Force > $null
try {
  New-Item -ItemType File -Path (Join-Path $tmp 'alpha.log') -Force > $null
  New-Item -ItemType File -Path (Join-Path $tmp 'beta.log') -Force > $null
  New-Item -ItemType File -Path (Join-Path $tmp 'beta.log.1') -Force > $null
  $env:NUCLEUS_LOG_DIR = $tmp
  $logs = @(& pwsh -NoProfile -File (Join-Path $repoRoot 'scripts/logs.ps1') -ListLogs -Scope user 2>$null)
  $ok = ($logs.Count -eq 2 -and $logs[0] -eq 'alpha' -and $logs[1] -eq 'beta')
  Assert-True -cond $ok -name 'logs.ps1 -ListLogs lists live log base names' -detail ($logs -join '|')
  $logsKebab = @(& pwsh -NoProfile -File (Join-Path $repoRoot 'scripts/logs.ps1') --list-logs -Scope user 2>$null)
  $okKebab = ($logsKebab.Count -eq 2 -and $logsKebab[0] -eq 'alpha' -and $logsKebab[1] -eq 'beta')
  Assert-True -cond $okKebab -name 'logs.ps1 --list-logs accepts kebab flag' -detail ($logsKebab -join '|')
} finally {
  # check-suppress:suppression_doc: cleanup of test-owned state must not fail the test when already gone
  Remove-Item Env:NUCLEUS_LOG_DIR -ErrorAction SilentlyContinue
  # check-suppress:suppression_doc: the temp dir is test-owned and may already be gone
  Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}

Write-Output "`n$passed passed, $failed failed"
if ($failed -gt 0) { exit 1 }
exit 0
