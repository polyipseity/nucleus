Register-Step -Number 8 -Name "CWD-independence tests" -Action {
  param($Step, $HasArgs, $RepoRoot, $WaveTmpDir, $PositionalArgs)

  Write-Message "skipping (POSIX-only test suite)."
  return $true
}
