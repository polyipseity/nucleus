Register-Step -Id "stale-nix-artifact" -Number 6 -Name "Stale Nix build artifact check" -Action {
  param()

  Write-Message "skipping (Nix not available on Windows)."
  return 2
}
