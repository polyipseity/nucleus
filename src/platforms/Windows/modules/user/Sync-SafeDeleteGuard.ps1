# Safe-delete guard for coding agents on Windows.
# Blocks cmd/cmd.exe and direct rm invocations.
# Deployed as a hook script; reads command from stdin.

param()

$inputText = [Console]::In.ReadToEnd()

# Block cmd.exe / cmd
if ($inputText -match 'cmd\.exe|(?<!\w)cmd(?!\w)') {
  [Console]::Error.WriteLine('BLOCKED: cmd.exe is not allowed. Use pwsh instead.')
  exit 2
}

# Block native rm invocation (absolute/relative path to rm)
if ($inputText -match '/bin/rm|/usr/bin/rm|/usr/local/bin/rm') {
  [Console]::Error.WriteLine('BLOCKED: native rm bypasses safe-delete protection. Use rip instead.')
  exit 2
}

# Block backslash-escaped deletion commands (alias bypass)
$escaped = @('rm','del','rd','rmdir','erase','ri','unlink','shred') | ForEach-Object { [regex]::Escape("\$_") }
$pattern = ($escaped -join '|')
if ($inputText -match $pattern) {
  [Console]::Error.WriteLine('BLOCKED: backslash-escaped deletion command bypasses safe-delete protection. Use rip instead.')
  exit 2
}

exit 0
