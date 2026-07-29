# Dynamic loader for test step files (PowerShell).
# Sources all *.ps1 files in the test-steps directory.

$ScriptDir = Split-Path -Parent $PSCommandPath
Get-ChildItem -Path "$ScriptDir/test-steps" -Filter '*.ps1' | Sort-Object Name | ForEach-Object { . $_.FullName }
