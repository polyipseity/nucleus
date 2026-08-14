Register-Step -Id "system-config-build" -Name "System config build" -Action {
  param()
  Skip-Step -Number (Get-StepNumber) -Name "System config build" -Reason "POSIX-only test suite"
  return 2
}
