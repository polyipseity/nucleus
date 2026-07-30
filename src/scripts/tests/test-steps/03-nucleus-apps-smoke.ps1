Register-Step -Number 3 -Name "Nucleus apps smoke tests" -Action {
  param($Step, $HasArgs, $RepoRoot, $WaveTmpDir, $PositionalArgs)
  $null = $Step, $HasArgs, $RepoRoot, $WaveTmpDir, $PositionalArgs  # check-suppress:SuppressMessageAttribute: PSUseDeclaredVarsMoreThanAssignments — intentionally unused parameters in stub
  Write-Message "skipping (requires Nix and bash — not available on Windows)."
  return $true
}
