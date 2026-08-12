Register-Step -Id "nix-tests" -Number 1 -Name "Nix test suite" -Action {
  param($RepoRoot)

  $lib = Join-Path -Path $RepoRoot -ChildPath 'src/scripts/lib/nix-test-eval.ps1'
  . $lib
  try {
    Invoke-NixTestEval -HasArgs $false -RepoRoot $RepoRoot > $null
  } catch {
    return 1
  }

  $testScript = Join-Path -Path $RepoRoot -ChildPath 'tests/scripts/check-steps/nix-test-eval-tests.ps1'
  & $testScript
  if ($LASTEXITCODE -ne 0) { return 1 }

  Write-Message "skipping (requires Nix toolchain — not available on Windows)."
  return 2
}
