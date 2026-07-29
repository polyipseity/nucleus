Register-Step -Number 9 -Name "Nix search path tests" -Action {
  param($Step, $HasArgs, $RepoRoot, $WaveTmpDir, $PositionalArgs)

  Write-Message "skipping (Nix not available on Windows)."
  return $true
}
