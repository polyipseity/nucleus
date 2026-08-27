#!/usr/bin/env bash
# Write the VS Code agent-host wrapper to the SYSTEM root bin.
# Args: $1 = wrapper path (may contain spaces), $2 = absolute shell exe.
set -euo pipefail

_wrapper_path="$1"
_shell_exe="$2"

# Quoted so a path with spaces (e.g. /Library/Application Support/...) is not
# word-split. install creates the parent dir; the wrapper is written via a
# quoted heredoc delimiter so only $_shell_exe expands at write time.
install -d -m 0755 "$(dirname "$_wrapper_path")"
cat >"$_wrapper_path" <<WRAPPER
export NUCLEUS_AGENT_SESSION=1
export VSCODE_AGENT=1
exec ${_shell_exe} "\$@"
WRAPPER
/bin/chmod +x "$_wrapper_path"
