Register-Step -Id "nix-lint" -Number 4 -Name "Nix lint (nixf-tidy)" -Action {
  param()

  Write-Message "skipping (nixf-tidy not available on Windows)."
  return 2
}
