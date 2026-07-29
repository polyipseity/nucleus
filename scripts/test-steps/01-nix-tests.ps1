Register-Step -Number 1 -Name "Nix test suite" -Action {
  param($Step, $HasArgs, $RepoRoot, $WaveTmpDir, $PositionalArgs)
  Write-Message "skipping (requires Nix toolchain — not available on Windows)."
  return $true
}
