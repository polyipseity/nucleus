#Requires -Version 7.4
# Logging-format policy fixture: clean PowerShell file (no violations).
# WHY: the parameter below is named EventName because PowerShell reserves `Event`
# as an automatic variable. That is a comment mentioning the reserved name, not an
# escape sequence.
# WHY: the `Event` mention stays clean with or without -CaseSensitive, because the
# pattern needs a token end after the e; the step passes the flag for parity with
# the case-sensitive awk twin.
function Invoke-Clean { Write-Output 'clean' }
