Register-Step -Id "system-config-build" -Number 4 -Name "System config build" -Action {
  param()
  Write-Message "skipping (system config build is POSIX-only)."
  return 2
}
