Register-Step -Number 10 -Name "Port utility function tests" -Action {
  param()

  Write-Message "skipping (POSIX-only test suite)."
  return $true
}
