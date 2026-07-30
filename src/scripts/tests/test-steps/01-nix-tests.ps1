Register-Step -Number 1 -Name "Nix test suite" -Action {
  param($Step, $HasArgs, $RepoRoot, $WaveTmpDir, $PositionalArgs)
  $null = $Step, $HasArgs, $RepoRoot, $WaveTmpDir, $PositionalArgs  # check-suppress:SuppressMessageAttribute: PSUseDeclaredVarsMoreThanAssignments — intentionally unused parameters in stub
  Write-Message "skipping (requires Nix toolchain — not available on Windows)."
  return $true
}
