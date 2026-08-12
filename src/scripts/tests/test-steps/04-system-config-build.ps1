Register-Step -Id "system-config-build" -Name "System config build" -Action {
  param()
  Write-Message "==== $(Get-StepNumber): System config build ==== SKIPPED (POSIX-only test suite)"
  return 2
}
