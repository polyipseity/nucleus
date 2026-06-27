---
description: "Use when editing launchd plist configuration for system daemons on macOS. Documents SIP log-path restrictions and the approved /Users/Shared/logs directory."
name: "macOS launchd log path restriction"
applyTo: "src/modules/logging.nix, src/hosts/MacBook/**"
---

# macOS launchd log path restriction

## Problem

On macOS 26+, SIP blocks launchd from writing to `/Library/Logs/` for system daemons with a non-root `UserName`. The service fails with EX_CONFIG (78).

## Symptoms

- `sudo launchctl print system/<service>` shows `last exit code = 78: EX_CONFIG`
- Log files under `/Library/Logs/nucleus/` are empty or don't exist
- The same binary/script works when run directly via `sudo -u user /path/to/program`
- The same plist works with `StandardOutPath`/`StandardErrorPath` pointing to `/tmp/` or `/Users/Shared/`
- launchd logs (`log show`) show no errors

## Fix

Use `/Users/Shared/nucleus/logs` instead of `/Library/Logs/nucleus` for `StandardOutPath`/`StandardErrorPath` in launchd plists.

Defined in `src/modules/logging.nix`:

- `systemLogDir` default on Darwin = `/Users/Shared/nucleus/logs`

## Verified working paths

- `/Users/Shared/` ✅ (persistent, no SIP issues)
- `/tmp/` ✅ (ephemeral, for testing)
- `/Library/Logs/` ❌ (blocked by SIP on macOS 26+)
