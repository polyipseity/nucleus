Register-Step -Number 4 -Name "System config build" -Action {
  param($Step, $HasArgs, $RepoRoot, $WaveTmpDir, $PositionalArgs)
  $null = $Step, $HasArgs, $RepoRoot, $WaveTmpDir, $PositionalArgs  # check-suppress:SuppressMessageAttribute: PSUseDeclaredVarsMoreThanAssignments — intentionally unused parameters in stub
  Write-Message "skipping (system config build is POSIX-only)."
  return $true
}
