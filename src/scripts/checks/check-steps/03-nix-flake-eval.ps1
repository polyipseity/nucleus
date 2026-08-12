Register-Step -Id "nix-flake-eval" -Name "Nix flake evaluation" -Action {
  param()

  Write-Message "skipping (Nix not available on Windows)."
  return 2
}
