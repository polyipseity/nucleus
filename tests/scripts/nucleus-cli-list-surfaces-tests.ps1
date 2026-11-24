# D4: list surfaces for nucleus CLI dynamic providers (Windows twins, parse/smoke checks).

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Split-Path -Parent (Split-Path -Parent $scriptDir)
$prevNucleusRepoRoot = $env:NUCLEUS_REPO_ROOT
$env:NUCLEUS_REPO_ROOT = $repoRoot
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

Write-Output "`n=== [4] svc.ps1 POSIX delegation ==="
if (-not $IsWindows) {
  $svcPs1 = Join-Path $repoRoot 'scripts/svc.ps1'
  $svcSh = Join-Path $repoRoot 'scripts/svc.sh'
  $psSvc = @(& pwsh -NoProfile -File $svcPs1 --list-services 2>$null)
  $shSvc = @(& bash $svcSh --list-services 2>$null)
  $svcOk = ($psSvc.Count -gt 0 -and (($psSvc -join "`n") -eq ($shSvc -join "`n")))
  Assert-True -cond $svcOk -name 'svc.ps1 --list-services delegates to svc.sh on POSIX' -detail ("ps=" + ($psSvc -join '|') + " sh=" + ($shSvc -join '|'))
  $psList = (& pwsh -NoProfile -File $svcPs1 list 2>&1 | Out-String).Trim()
  $shList = (& bash $svcSh list 2>&1 | Out-String).Trim()
  Assert-True -cond ($LASTEXITCODE -eq 0 -and $psList.Length -gt 0 -and $psList -eq $shList) -name 'svc.ps1 list delegates to svc.sh on POSIX'
} else {
  Write-Output "- SKIP: svc.ps1 POSIX delegation (Windows host)"
}

Write-Output "`n=== [5] spec --list-* conformance (PowerShell) ==="
$specFile = Join-Path $repoRoot 'src/modules/completions/nucleus-cli-spec.json'
$specText = Get-Content $specFile -Raw
$foundFlags = @([regex]::Matches($specText, '--list-[a-z-]+') | ForEach-Object { $_.Value } | Sort-Object -Unique)
$expected = @('--list-endpoints','--list-logs','--list-replicas','--list-sections','--list-services','--list-steps')
$specOk = (($foundFlags -join ',') -eq ($expected -join ','))
Assert-True -cond $specOk -name 'spec --list-* inventory matches expected set' -detail ($foundFlags -join '|')

function Invoke-ListFlag([string]$label, [scriptblock]$cmd) {
  $out = @(& $cmd 2>$null)
  $rc = $LASTEXITCODE
  $ok = ($rc -eq 0 -and $out.Count -gt 0)
  Assert-True -cond $ok -name "$label rc=0 and produces output" -detail ("rc=$rc out=" + (($out | Select-Object -First 1) -join ''))
}

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("nucleus-cli-conformance-" + [Guid]::NewGuid().ToString('n'))
New-Item -ItemType Directory -Path $tmp -Force > $null
New-Item -ItemType File -Path (Join-Path $tmp 'alpha.log') -Force > $null
New-Item -ItemType File -Path (Join-Path $tmp 'beta.log') -Force > $null
try {
  $env:NUCLEUS_LOG_DIR = $tmp
  Invoke-ListFlag 'check.ps1 --list-steps' { & pwsh -NoProfile -File (Join-Path $repoRoot 'scripts/check.ps1') --list-steps }
  Invoke-ListFlag 'cloud.ps1 --list-replicas' { & pwsh -NoProfile -File (Join-Path $repoRoot 'scripts/cloud.ps1') --list-replicas }
  Invoke-ListFlag 'gc.ps1 --list-logs' { & pwsh -NoProfile -File (Join-Path $repoRoot 'scripts/gc.ps1') --list-logs }
  Invoke-ListFlag 'logs.ps1 --list-logs' { & pwsh -NoProfile -File (Join-Path $repoRoot 'scripts/logs.ps1') --list-logs }
  Invoke-ListFlag 'svc.ps1 --list-services' { & pwsh -NoProfile -File (Join-Path $repoRoot 'scripts/svc.ps1') --list-services }
  Invoke-ListFlag 'test.ps1 --list-steps' { & pwsh -NoProfile -File (Join-Path $repoRoot 'scripts/test.ps1') --list-steps }
  Invoke-ListFlag 'update.ps1 lockfile --list-sections' { & pwsh -NoProfile -File (Join-Path $repoRoot 'scripts/update.ps1') lockfile --list-sections }

  if (-not $IsWindows) {
    $hostName = if ((uname -s).Trim() -eq 'Darwin') { 'MacBook' } else { 'NixOS' }
    $svcJson = Get-Content (Join-Path $repoRoot 'src/modules/services.json') -Raw | ConvertFrom-Json -AsHashtable
    $svcWithEp = $null
    foreach ($svc in @(& bash (Join-Path $repoRoot 'scripts/svc.sh') --list-services 2>$null)) {
      $s = [string]$svc
      if ([string]::IsNullOrWhiteSpace($s) -or $s.Contains('\')) { continue }
      $entry = $svcJson[$s]
      if ($null -eq $entry) { continue }
      $h = $entry.hosts[$hostName]
      if ($null -eq $h -or $h.type -eq 'omitted') { continue }
      $net = if ($entry.ContainsKey('network')) { $entry['network'] } else { $null }
      if ($null -ne $net -and @($net).Count -gt 0) { $svcWithEp = $s; break }
    }
    if ($svcWithEp) {
      Invoke-ListFlag "svc.ps1 endpoint $svcWithEp --list-endpoints" { & pwsh -NoProfile -File (Join-Path $repoRoot 'scripts/svc.ps1') endpoint $svcWithEp --list-endpoints }
    } else {
      Assert-True -cond $false -name 'svc.ps1 endpoint --list-endpoints has host service with network endpoints'
    }
  } else {
    Write-Output "- SKIP: svc.ps1 endpoint --list-endpoints (covered by CI on Windows)"
  }
} finally {
  Remove-Item Env:NUCLEUS_LOG_DIR -ErrorAction SilentlyContinue
  Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}

Write-Output "`n=== [6] kebab flag binding (param-block scripts) ==="
$kebabCases = @(
  @{ name='ai.ps1 --no-gc-only --help binds'; args=@('--no-gc-only','--help') ; cmd='scripts/ai.ps1' },
  @{ name='bootstrap.ps1 --no-replica-sync --help binds'; args=@('--no-replica-sync','--help') ; cmd='scripts/bootstrap.ps1' },
  @{ name='bootstrap.ps1 --no-apply --unknown-passthrough --help passes unknown flag through'; args=@('--no-apply','--unknown-passthrough','--help') ; cmd='scripts/bootstrap.ps1' },
  @{ name='cloud.ps1 --dry-run --list-replicas binds'; args=@('--dry-run','--list-replicas') ; cmd='scripts/cloud.ps1' },
  @{ name='gc.ps1 --dry-run --list-logs binds'; args=@('--dry-run','--list-logs') ; cmd='scripts/gc.ps1' },
  @{ name='gc.ps1 --log-max-size 1000000 --dry-run --list-logs binds'; args=@('--log-max-size','1000000','--dry-run','--list-logs') ; cmd='scripts/gc.ps1' },
  @{ name='logs.ps1 --list-logs binds'; args=@('--list-logs') ; cmd='scripts/logs.ps1' }
)
foreach ($k in $kebabCases) {
  $out = & pwsh -NoProfile -File (Join-Path $repoRoot $k.cmd) @($k.args) 2>&1
  $rc = $LASTEXITCODE
  $txt = (($out | ForEach-Object { "$_" }) -join "`n")
  $hasParamErr = $txt -match 'parameter cannot be found|A parameter cannot be found'
  Assert-True -cond ($rc -eq 0 -and -not $hasParamErr) -name $k.name -detail ("rc={0}" -f $rc)
}

# svc regression: --lines must bind as a parameter, not cause a binding error.
$svcOut = & pwsh -NoProfile -File (Join-Path $repoRoot 'scripts/svc.ps1') list --lines 5 2>&1
$svcRc = $LASTEXITCODE
$svcTxt = (($svcOut | ForEach-Object { "$_" }) -join "`n")
$svcBindErr = $svcTxt -match 'parameter cannot be found|A parameter cannot be found'
Assert-True -cond (-not $svcBindErr) -name 'svc.ps1 list --lines 5 binds --lines' -detail ("rc={0}" -f $svcRc)

$vmOut = & pwsh -NoProfile -File (Join-Path $repoRoot 'scripts/vm.ps1') sync --dry-run 2>&1
$vmTxt = (($vmOut | ForEach-Object { "$_" }) -join "`n")
$vmBindErr = $vmTxt -match "unknown flag '--dry-run'|parameter cannot be found|A parameter cannot be found"
Assert-True -cond (-not $vmBindErr) -name 'vm.ps1 sync --dry-run is not rejected as unknown normalizer flag' -detail ("rc={0} out={1}" -f $LASTEXITCODE, $vmTxt)

if ($null -eq $prevNucleusRepoRoot) { Remove-Item Env:NUCLEUS_REPO_ROOT -ErrorAction SilentlyContinue } else { $env:NUCLEUS_REPO_ROOT = $prevNucleusRepoRoot }
Write-Output "`n$passed passed, $failed failed"
if ($failed -gt 0) { exit 1 }
exit 0
