Register-Step -Number 6 -Name "Stale Nix build artifact check" -Action {
  param($Step, $HasArgs, $RepoRoot, $WaveTmpDir, $PositionalArgs)

  Write-Message "skipping (Nix not available on Windows)."
  return $true
}
