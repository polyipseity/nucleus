# Dynamic loader for test step files (PowerShell).
# Sources all *.ps1 files in the test-steps directory.
# $TestDir is set by the orchestrator before sourcing this file.

Get-ChildItem -Path "$TestDir/test-steps" -Filter '*.ps1' | Sort-Object Name | ForEach-Object { . $_.FullName }
