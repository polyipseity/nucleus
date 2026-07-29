# Dynamic loader for check step files (PowerShell).
# Sources all *.ps1 files in the check-steps directory.
# $CheckDir is set by the orchestrator before sourcing this file.

Get-ChildItem -Path "$CheckDir/check-steps" -Filter '*.ps1' | Sort-Object Name | ForEach-Object { . $_.FullName }
