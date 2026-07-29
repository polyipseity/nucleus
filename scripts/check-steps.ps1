# Dynamic loader for check step files (PowerShell).
# Sources all *.ps1 files in the check-steps directory.

$ScriptDir = Split-Path -Parent $PSCommandPath
Get-ChildItem -Path "$ScriptDir/check-steps" -Filter '*.ps1' | Sort-Object Name | ForEach-Object { . $_.FullName }
