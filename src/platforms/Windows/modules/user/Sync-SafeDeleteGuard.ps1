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

# Block native rm invocation (absolute/relative path to rm)
if ($inputText -match '/bin/rm|/usr/bin/rm|/usr/local/bin/rm') {
  Write-Host "BLOCKED: native rm bypasses safe-delete protection. Use rip instead." -ForegroundColor Red
  exit 2
}

# Block backslash-escaped deletion commands (alias bypass)
$escaped = @('rm','del','rd','rmdir','erase','ri','unlink','shred') | ForEach-Object { [regex]::Escape("\$_") }
$pattern = ($escaped -join '|')
if ($inputText -match $pattern) {
  Write-Host "BLOCKED: backslash-escaped deletion command bypasses safe-delete protection. Use rip instead." -ForegroundColor Red
  exit 2
}

exit 0
