#!/bin/sh
# Safe-delete guard for coding agents: blocks dangerous deletion commands.
# Reads command from stdin (hook JSON protocol) and exits 2 to deny.
# check-suppress:embedded-content: agent hook script, not a template

# Read stdin
input=$(cat)

# Extract command from JSON (simple grep-based, no jq dependency)
cmd=$(printf '%s' "$input" | grep -o '"command"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*: *"//;s/"$//')

# WHY a lowercased copy: the filter twins fold case for these families, so a
# guard that matched only lowercase spellings would deny a form one platform
# folds and allow its uppercase twin. `sh` has no `shopt`, so the fold is a copy
# lowered with `tr`, which is POSIX and sits beside the grep and sed already here.
lc_cmd=$(printf '%s' "$cmd" | tr '[:upper:]' '[:lower:]')

# Block direct native rm invocation (absolute/relative path to rm).
# WHY: no `/usr/bin/` or `/usr/local/bin/` alternative: `*/bin/rm*` already
# matches both, and a redundant alternative is dead code shellcheck reports.
case "$lc_cmd" in
*/bin/rm* | ./*rm*)
  printf '%s\n' "BLOCKED: native rm bypasses safe-delete protection. Use shell-safe-rm or rip2 instead." >&2
  exit 2
  ;;
esac

# Block backslash-escaped deletion commands (alias bypass).
# WHY: no `*'\rmdir'*` alternative: the glob only asks that the literal `\rm`
# appear somewhere in the command, so every escaped rmdir spelling already
# matches.
case "$lc_cmd" in
*'\rm'* | *'\del'* | *'\rd'* | *'\erase'* | *'\ri'* | *'\unlink'* | *'\shred'*)
  printf '%s\n' "BLOCKED: backslash-escaped deletion command bypasses safe-delete protection. Use shell-safe-rm or rip2 instead." >&2
  exit 2
  ;;
esac

# Block cmd.exe on any platform (Windows-specific but guard runs everywhere)
case "$lc_cmd" in
*cmd.exe* | *" cmd "*)
  printf '%s\n' "BLOCKED: cmd.exe is not allowed. Use pwsh instead." >&2
  exit 2
  ;;
esac

exit 0
