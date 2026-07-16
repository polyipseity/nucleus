---
description: "Use when debugging Electron/Chromium apps on macOS that don't inherit the expected PATH despite correct launchctl setenv, or when modifying env var propagation for Electron apps."
name: "Electron/Chromium macOS PATH Sanitization"
applyTo: "src/modules/macos.nix, src/modules/lib/env-vars.nix, src/hosts/MacBook/**"
---

Chromium-based apps on macOS internally sanitize `PATH` at process startup, overriding the value set in the launchd GUI domain via `launchctl setenv`. This affects every Electron app (Obsidian, VS Code, Discord, Slack, etc.) and can cause confusing debugging sessions where `launchctl getenv PATH` shows the correct value but the app's process has a different one.

## Root cause

Chromium's `SanitizeEnvironmentVariables` function in `base/mac/environment_variables.cc` strips `PATH` to system defaults as a security hardening measure. The logic replaces the process PATH with a safe subset — typically `/usr/bin:/bin:/usr/sbin:/sbin` with optional `/usr/local/bin` depending on the Electron version. This prevents dylib hijacking via a compromised PATH.

The Chromium source file is `base/mac/environment_variables.cc` — the sanitization applies unconditionally on macOS but does not target PATH on Linux or Windows.

## Diagnosis

If an Electron app shows the wrong PATH despite `launchctl getenv PATH` returning the correct value:

1. Verify the app is actually Electron/Chromium: check `Info.plist` for `ElectronTeamID` or examine `Frameworks/Electron Framework.framework/`.
2. Check the app's process environment: `ps ewww -p <pid> | tr ' ' '\n' | grep "^PATH="`. The value will be a sanitized system PATH, possibly with minor version-dependent differences (e.g., some Electron versions include `/usr/local/bin`, others don't).
3. Confirm non-PATH env vars are unaffected: `ps ewww -p <pid> | tr ' ' '\n' | grep "EDITOR"` etc. If non-PATH vars are correct, the `gui-env` LaunchAgent works — PATH sanitization is the sole issue.
4. The observed PATH values differ by Electron build configuration, not by launch timing or launchd state — this is not a race condition.

## Scope

- **Affected**: All Electron/Chromium apps on macOS. The PID 1 (launchd) parent makes the env var source clearly traceable via `ps ewww`.
- **Not affected**: Native macOS apps (terminal, Calendar, Finder, etc.) correctly inherit from `launchctl setenv`.
- **Not affected**: Electron apps on Linux (Chromium's sanitization targets different variables like `LD_LIBRARY_PATH`) or Windows (uses `GetEnvironmentVariable` without sanitization).

## Workaround (not yet implemented)

A proper fix is deferred. Approaches considered:

- **LSEnvironment**: Add `PATH` to the app's `Info.plist` `LSEnvironment` dictionary. Works for `/Applications/` apps but requires plist patching per app.
- **Wrapper script**: Replace the app binary with a shell script that injects PATH before exec'ing the real Electron binary. Works for Nix-store apps.
- **launchd.plist wrapper**: Launch the app via a custom launchd agent that sets PATH in the process environment directly.

## Cross-host parity

| Host    | Env var mechanism                       | Electron PATH sanitization?                                     |
| ------- | --------------------------------------- | --------------------------------------------------------------- |
| macOS   | `launchctl setenv` via `gui-env` agent  | Yes — Electron strips PATH internally                           |
| NixOS   | `environment.variables` → PAM + systemd | No — Chromium only targets macOS launchd-specific vars          |
| Windows | Registry Machine/User scope (DSC)       | No — Windows Electron uses unsanitized `GetEnvironmentVariable` |
