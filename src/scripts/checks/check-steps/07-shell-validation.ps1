Register-Step -Id "shell-validation" -Number 7 -Name "Shell script validation tests" -Action {
  param()

  Write-Message "skipping (POSIX-only test suite)."
  return 2
}
