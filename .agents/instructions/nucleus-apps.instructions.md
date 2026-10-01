---
description: "Use when adding, renaming, or reviewing nucleus command-surface entries (flake apps, scripts/*.sh/.ps1, or subcommand dispatch). Covers the canonical command set, the no-new-single-purpose-command rule, internal-invocation policy, Windows parity, completion generation, and the agent-host-shell wrapper location."
name: "Nucleus Command Surface"
applyTo: "src/flake.nix, scripts/**/*.sh, scripts/**/*.ps1, src/scripts/**/*.sh, src/scripts/completions/**, src/modules/shell/default.nix"
---

# Nucleus command surface

Every `nucleus-*` command is declared once in `mkNucleusApps` (`src/flake.nix`); `home.packages`, the flake `apps` output, and `packages` all derive from it, so never hand-register a command anywhere else. Deleting an entry removes it from every surface at once. The `apps` output strips the `nucleus-` prefix, so `nix run .#check` reaches `nucleus-check`.

`service-watchdog` is the exception: a daemon, not an app. It stays out of `mkNucleusApps`, never appears on PATH or `nix run`, and runs only from its store path under systemd or launchd. `nucleus-utils` groups user utilities such as `optimize-pdf`.

## Adding functionality

Stop at the first fit:

1. Not user-facing (library, daemon helper, activation step): keep it a plain script, with no PATH command.
2. A variant of an existing app: add a subcommand to `check`, `gc`, `apply`, `cloud`, or `update`.
3. A new top-level concern: register it in `mkNucleusApps` with a matching `scripts/<name>.sh` and `scripts/<name>.ps1`. A daemon-only entry skips `home.packages`.

The command set is shared with the completion generators and check step `10-completions-fresh`, so change one and the other or freshness fails.

## Internal invocation

Internal code must not call a `nucleus-*` PATH command: that couples activation to a user-installed profile. Call the logic through the script entry (`scripts/<name>.sh` or `.ps1`), the flake attr (`src#<name>`), or the store path (`${nucleusApps.nucleus-<name>}/bin/nucleus-<name>`, as `service-watchdog.nix` and `activation.nix` do).

## Platform rules

`nucleus-bootstrap` installs Nix and base deps only, must not assume prior state, and must succeed on a bare machine. It may call apply through `--apply`/`-Apply` once the deps exist, but apply is never a bootstrap dependency.

Windows provisioning self-elevates through `RunAs`, so writing to `%ProgramData%\nucleus\bin` is admin-normal: no non-admin fallback and no degraded branch, matching the inverse-family exception in `apply.ps1`.

Every POSIX `scripts/<name>.sh` with subcommands needs a `scripts/<name>.ps1` twin with a matching `[ValidateSet(...)]` `$Action` dispatch and the same subcommand vocabulary. `apply` has a twin too, since `src/hosts/Windows/apply.ps1` consumes it for `health-check` and `audit-store`.

## Completions

`src/scripts/completions/gen-completions.sh` and `gen-completions.ps1` derive completions from `--help` output. Regenerate and commit after a command-surface change; step `10-completions-fresh` re-runs them in check mode and fails on a diff. Never hand-edit generated files.

## Agent host wrapper

The VS Code agent host wrapper is system-level, never per-user and never symlinked from `src/users/`. POSIX installs it into the SYSTEM root bin (`/Library/Application Support/nucleus/bin/agent-host-shell` on macOS, `/var/lib/nucleus/bin/agent-host-shell` on NixOS) from `src/modules/posix/agent-host-shell.nix`; Windows uses `%ProgramData%\nucleus\bin\agent-host-shell.ps1` from `Invoke-AgentHostShellSetup.ps1`.
