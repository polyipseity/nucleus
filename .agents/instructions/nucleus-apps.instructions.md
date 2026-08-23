---
description: "Use when adding, renaming, or reviewing nucleus command-surface entries (flake apps, scripts/*.sh/.ps1, or subcommand dispatch). Covers the canonical command set, the no-new-single-purpose-command rule, internal-invocation policy, Windows parity, completion generation, and the agent-host-shell wrapper location."
name: "Nucleus Command Surface"
applyTo: "src/flake.nix, scripts/**/*.sh, scripts/**/*.ps1, src/scripts/**/*.sh, src/scripts/completions/**, src/modules/shell.nix"
---

# Nucleus command surface

## Canonical command set

The user-facing CLI is a fixed set of ~12 flake apps, each a `nucleus-<name>` package built by `mkNucleusApps` in `src/flake.nix`. The flake `apps` output strips the `nucleus-` prefix so they run as `nix run .#<name>`:

- `apply`, `ai`, `bootstrap`, `check`, `config`, `gs-pdf-opt`, `gc`, `svc`, `service-watchdog`, `test`, `update`, `vm`, `cloud`

`service-watchdog` is a package but is excluded from `home.packages` (`src/modules/shell.nix` removes it via `builtins.removeAttrs nucleusApps [ "nucleus-service-watchdog" ]`). It runs only under systemd/launchd (`src/hosts/NixOS/activation.nix`, `src/hosts/MacBook/service-watchdog.nix`), never from a user PATH.

## No new single-purpose commands

Do NOT add new single-purpose `nucleus-<x>` PATH commands. Fold new functionality into one of these:

- A **subcommand** of an existing parent command (`check`, `gc`, `apply`, `cloud`, `update`).
- A **new parent command** added to `mkNucleusApps` in `src/flake.nix` (with a matching `scripts/<name>.sh` / `scripts/<name>.ps1` entry and a `home.packages` registration unless it is daemon-only like `service-watchdog`).

The command set is the coverage contract shared with the completion generators and check step `10-completions-fresh`. Adding a command without updating both breaks freshness enforcement.

## Internal-invocation policy

Internal code must NOT call `nucleus-*` PATH commands. This includes daemons, apply post-steps, scheduled tasks, and activation scripts. Invoke the underlying logic by one of:

- The **script entry**: `scripts/<name>.sh` (POSIX) or `scripts/<name>.ps1` (Windows).
- The **flake attr**: `src#<name>` (e.g. `nix run .#check`).
- A **store path**: `${nucleusApps.nucleus-<name>}/bin/nucleus-<name>` (used by `service-watchdog.nix` / `activation.nix`).

PATH commands are a user convenience surface, not an internal API. Relying on them inside the system couples activation to a user-installed profile.

## Windows parity

Every POSIX `scripts/<name>.sh` that exposes subcommands needs a `scripts/<name>.ps1` twin with matching `[ValidateSet(...)]` `$Action` dispatch. The two entry points must accept the same subcommand vocabulary so `nix run .#<name>` behaves identically on macOS/NixOS and Windows.

## Completion generators

`src/scripts/completions/gen-completions.sh` (zsh) and `gen-completions.ps1` (pwsh) are the source of truth for completions. They derive completions from each command's `--help` output. After any change to the command surface (new command, renamed subcommand, changed `[ValidateSet]`), regenerate and commit the output. Check step `10-completions-fresh` enforces freshness: it re-runs the generators in check mode and fails on any diff. Generated completion files must not be edited by hand.

## Agent-host-shell wrapper

The VS Code agent-host wrapper lives outside the user HOME:

- POSIX: `/etc/nucleus/bin/agent-host-shell` (`src/modules/agent-host-shell.nix`).
- Windows: `%ProgramData%\nucleus\bin\agent-host-shell.ps1` (`src/platforms/Windows/modules/system/Invoke-AgentHostShellSetup.ps1`).

It is a system-level provisioning artifact, not a per-user dotfile. Do not relocate it into HOME or symlink it from `src/users/`.
