Register-Step -Number 4 -Name "Nix flake evaluation" -Action {
  param($Step, $HasArgs, $RepoRoot, $WaveTmpDir, $PositionalArgs)

  Write-Message "skipping (Nix not available on Windows)."
  return $true
}
