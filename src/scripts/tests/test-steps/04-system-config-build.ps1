Register-Step -Id "system-config-build" -Name "System config build" -Action {
  param([Parameter(Mandatory)][PSObject]$Context)

  Skip-Step -Number (Get-StepNumber -Context $Context) -Name "System config build" -Reason "POSIX-only test suite"
  return 2
}
