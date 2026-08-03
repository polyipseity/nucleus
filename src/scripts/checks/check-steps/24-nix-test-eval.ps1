Register-Step -Id "nix-test-eval" -Number 24 -Name "Nix test evaluation guard" -Action {
  param($HasArgs, $RepoRoot, $PositionalArgs)

  $r = if ($RepoRoot) { $RepoRoot } else { Split-Path -Parent (Split-Path -Parent $PSScriptRoot) }

  $violations = @()
  $selfLeaf = Split-Path -Leaf $PSCommandPath

  # Scan scope: Nix test files under tests/, excluding the shared test helper
  # lib.nix (see allow-and-deny-lists.instructions.md#A6). Non-.nix harness
  # files and fixtures outside tests/ are out of scope.
  $scanFiles = if ($HasArgs) {
    @($PositionalArgs | Where-Object {
      ($_ -like 'tests/*.nix') -and
      ((Split-Path -Leaf $_) -ne 'lib.nix') -and
      ((Split-Path -Leaf $_) -ne $selfLeaf)
    })
  } else {
    @(Get-ChildItem -Path (Join-Path $r 'tests') -Recurse -File -Filter '*.nix' |
      Where-Object { $_.Name -ne 'lib.nix' } |
      Where-Object { $_.Name -ne $selfLeaf } |
      ForEach-Object { $_.FullName } | Select-GitIgnored)  # ref: allow-and-deny-lists.instructions.md#C7 -- structural invariant; gitignore filter applied on top
  }

  # Pattern 1: 1-argument builtins.deepSeq inside builtins.seq — a partial
  # application.  `builtins.seq (builtins.deepSeq allTests) { ... }` forces only
  # the lambda (WHNF), never the tests: every assertion is silently skipped.
  # The 2-argument form with a second value (e.g. null) does not match.
  foreach ($file in $scanFiles) {
    $content = Get-Content -Raw -Path $file
    $lineNo = 0
    $hasLengthOnly = $content -match 'builtins\.length\s+(allTests|all_tests)'
    $hasSuccessTrue = $content -match 'success = true'
    $hasTopLevelAssert = [bool]($content -split "`r?`n" | Where-Object { $_ -match '^\s*assert\s' })
    $hasForcing = ($content -match 'builtins\.(seq|deepSeq|all|filter)') -or $hasTopLevelAssert
    foreach ($line in ($content -split "`r?`n")) {
      $lineNo++
      if ($line -match '^\s*builtins\.seq\s*\(\s*builtins\.deepSeq\s+[A-Za-z_][A-Za-z0-9_]*\s*\)') {
        $violations += "${file}:${lineNo}: 1-argument builtins.deepSeq is a partial application — it never forces the tests (use builtins.seq (builtins.deepSeq allTests) null)"
      }
    }
    if ($hasLengthOnly -and $hasSuccessTrue -and -not $hasForcing) {
      $violations += "${file}: Nix tests are only counted via builtins.length but never forced — assertions are silently skipped (see .agents/instructions/testing.instructions.md)"
    }
  }

  if ($violations.Count -gt 0) {
    foreach ($v in $violations) {
      Write-Error "check: error: $v"
    }
    Write-Output "check:   Force evaluation of every test file — see .agents/instructions/testing.instructions.md."
    throw "Nix test evaluation check failed: $($violations.Count) violation(s) found."
  }

  Write-Output "check: all Nix test files force evaluation of their assertions."
}
