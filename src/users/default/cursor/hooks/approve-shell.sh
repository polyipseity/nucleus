#!/usr/bin/env bash
# Cursor `beforeShellExecution` gate: routes agent shell commands through the
# shared remote-approval broker so a pending command can be allowed or denied
# from a messaging channel.
#
# Cursor reads the JSON this script prints on stdout:
#   {"permission":"allow"|"ask"|"deny"}
# `ask` is Cursor's normal behaviour (prompt locally) and is also the answer for
# every failure path here — a hook that crashes must not silently authorise a
# command, and it must not silently block one either.
#
# The broker (`harness-approval`) prints exactly allow|deny|ask and owns the
# request/response state, the timeout, and the notification.
set -euo pipefail

_ase_decision="ask"
_ase_payload=""
if ! _ase_payload="$(cat)"; then
  _ase_payload=""
fi

_ase_command=""
if [ -n "$_ase_payload" ] && command -v jq >/dev/null 2>&1; then
  if ! _ase_command="$(printf '%s' "$_ase_payload" | jq -r '.command // empty' 2>/dev/null)"; then
    _ase_command=""
  fi
fi

if [ -n "$_ase_command" ]; then
  _ase_summary="${_ase_command:0:200}"
  if ! _ase_decision="$(harness-approval cursor Shell "$_ase_summary" 2>/dev/null)"; then
    _ase_decision="ask"
  fi
fi

case "$_ase_decision" in
allow | deny) ;;
*) _ase_decision="ask" ;;
esac

printf '{"permission":"%s"}\n' "$_ase_decision"
