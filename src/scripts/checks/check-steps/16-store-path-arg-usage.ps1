Register-Step -Id "store-path-arg-usage" -Name "Store-path arg variable usage enforcement" -Action {
  param([Parameter(Mandatory)][PSObject]$Context)

  # This check only applies to POSIX shell scripts (.sh). No PowerShell scripts
  # use the _X_bin="$N" store-path arg assignment pattern, so always skip.
  Skip-Step -Number (Get-StepNumber) -Name "Store-path arg variable usage enforcement" -Reason "this check only applies to POSIX shell scripts"
  return 2
}
