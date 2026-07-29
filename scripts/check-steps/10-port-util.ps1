Register-Step -Number 10 -Name "Port utility function tests" -Action {
  param($Step, $HasArgs, $RepoRoot, $WaveTmpDir, $PositionalArgs)

  Write-Message "skipping (POSIX-only test suite)."
  return $true
}
