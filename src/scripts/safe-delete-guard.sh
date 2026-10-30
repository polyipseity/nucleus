#!/bin/sh
# Safe-delete guard for coding agents: blocks dangerous deletion commands.
# Reads command from stdin (hook JSON protocol) and exits 2 to deny.
# check-suppress:embedded-content: agent hook script, not a template

# Read stdin
input=$(cat)

# Extract command from JSON (simple grep-based, no jq dependency)
cmd=$(printf '%s' "$input" | grep -o '"command"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*: *"//;s/"$//')

# Block direct native rm invocation (absolute/relative path to rm)
case "$cmd" in
*/bin/rm* | */usr/bin/rm* | */usr/local/bin/rm* | ./*rm*)
  printf '%s\n' "BLOCKED: native rm bypasses safe-delete protection. Use shell-safe-rm or rip2 instead." >&2
  exit 2
  ;;
esac

# Block backslash-escaped deletion commands (alias bypass)
case "$cmd" in
*'\rm'* | *'\del'* | *'\rd'* | *'\rmdir'* | *'\erase'* | *'\ri'* | *'\unlink'* | *'\shred'*)
  printf '%s\n' "BLOCKED: backslash-escaped deletion command bypasses safe-delete protection. Use shell-safe-rm or rip2 instead." >&2
  exit 2
  ;;
esac

# Block cmd.exe on any platform (Windows-specific but guard runs everywhere)
case "$cmd" in
*cmd.exe* | *" cmd "*)
  printf '%s\n' "BLOCKED: cmd.exe is not allowed. Use pwsh instead." >&2
  exit 2
  ;;
esac

exit 0
