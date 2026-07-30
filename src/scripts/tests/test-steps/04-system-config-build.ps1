Register-Step -Number 4 -Name "System config build" -Action {
  param()
  Write-Message "skipping (system config build is POSIX-only)."
  return $true
}
