Register-Step -Number 8 -Name "CWD-independence tests" -Action {
  param()

  Write-Message "skipping (POSIX-only test suite)."
  return $true
}
