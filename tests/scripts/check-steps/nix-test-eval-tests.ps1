# Test: nix-test-eval guard (src/scripts/lib/nix-test-eval.ps1) behavioral checks.

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
$testFile = Join-Path -Path $repoRoot -ChildPath 'src/scripts/lib/nix-test-eval.ps1'

. $testFile

if (-not (Test-Path -LiteralPath $testFile)) {
  throw "missing nix-test-eval lib: $testFile"
}

$content = Get-Content -Raw -Path $testFile
if ($content -notmatch 'function Invoke-NixTestEval') {
  throw 'nix-test-eval PS1 should define Invoke-NixTestEval'
}

$tmpDir = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("nucleus-nix-test-eval-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path (Join-Path $tmpDir 'tests') -Force > $null

try {
  @'
builtins.seq (builtins.deepSeq allTests) {
  success = true;
  testCount = builtins.length allTests;
}
'@ | Set-Content -Path (Join-Path $tmpDir 'tests/bad-deepseq.nix') -NoNewline

  $rejected = $false
  try {
    Invoke-NixTestEval -HasArgs $true -RepoRoot $tmpDir -PositionalArgs @('tests/bad-deepseq.nix') > $null
  } catch {
    $rejected = $true
  }
  if (-not $rejected) {
    throw 'nix-test-eval PS1 should reject 1-argument builtins.deepSeq in scoped mode'
  }

  @'
builtins.seq (builtins.deepSeq allTests null) {
  success = true;
  testCount = builtins.length allTests;
}
'@ | Set-Content -Path (Join-Path $tmpDir 'tests/good-deepseq.nix') -NoNewline

  Invoke-NixTestEval -HasArgs $true -RepoRoot $tmpDir -PositionalArgs @('tests/good-deepseq.nix') > $null
} finally {
  # check-suppress:suppression_doc: tmp dir cleanup in test teardown; missing path is acceptable.
  Remove-Item -LiteralPath $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
}
