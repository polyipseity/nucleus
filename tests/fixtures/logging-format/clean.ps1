#Requires -Version 7.4
# Logging-format policy fixture: clean PowerShell file (no violations).
# WHY: the parameter below is named EventName because PowerShell reserves `Event`
# as an automatic variable. That is a comment mentioning the reserved name, not an
# escape sequence, so a case-insensitive backtick-e scan would report a false
# violation here.
function Invoke-Clean { Write-Output 'clean' }
