Register-Step -Id "nix-search-path" -Number 9 -Name "Nix search path tests" -Action {
  param()

  Write-Message "skipping (Nix not available on Windows)."
  return $true
}
