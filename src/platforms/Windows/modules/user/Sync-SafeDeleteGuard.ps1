# Safe-delete guard for coding agents on Windows.
# Blocks cmd/cmd.exe and direct rm invocations.
# Deployed as a hook script; reads command from stdin.

param()

$inputText = [Console]::In.ReadToEnd()

# Block cmd.exe / cmd
if ($inputText -match 'cmd\.exe|(?<!\w)cmd(?!\w)') {
  Write-Host "BLOCKED: cmd.exe is not allowed. Use pwsh instead." -ForegroundColor Red
  exit 2
}

# Block /bin/rm (shouldn't appear on Windows but guard anyway)
if ($inputText -match '/bin/rm') {
  Write-Host "BLOCKED: /bin/rm bypasses safe-delete protection. Use rip instead." -ForegroundColor Red
  exit 2
}

exit 0
