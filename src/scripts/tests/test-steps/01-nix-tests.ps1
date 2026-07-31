Register-Step -Id "nix-tests" -Number 1 -Name "Nix test suite" -Action {
  param()
  Write-Message "skipping (requires Nix toolchain — not available on Windows)."
  return 2
}
