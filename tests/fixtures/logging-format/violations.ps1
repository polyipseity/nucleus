#Requires -Version 7.4
# Logging-format policy fixture: PowerShell file with every prohibited construct.
Write-Output ([char]27 + 'red')
Write-Output "`e[31mred`e[0m"
