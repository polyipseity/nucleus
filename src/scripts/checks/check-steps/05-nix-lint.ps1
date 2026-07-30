Register-Step -Number 5 -Name "Nix lint (nixf-tidy)" -Action {
  param()

  Write-Message "skipping (nixf-tidy not available on Windows)."
  return $true
}
