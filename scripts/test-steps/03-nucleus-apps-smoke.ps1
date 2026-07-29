Register-Step -Number 3 -Name "Nucleus apps smoke tests" -Action {
  param($Step, $HasArgs, $RepoRoot, $WaveTmpDir, $PositionalArgs)
  Write-Message "skipping (requires Nix and bash — not available on Windows)."
  return $true
}
