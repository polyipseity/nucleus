---
description: "Use when adding, renaming, or reviewing nucleus command-surface entries (flake apps, scripts/*.sh/.ps1, or subcommand dispatch). Covers the canonical command set, the no-new-single-purpose-command rule, internal-invocation policy, Windows parity, completion generation, and the agent-host-shell wrapper location."
name: "Nucleus Command Surface"
applyTo: "src/flake.nix, scripts/**/*.sh, scripts/**/*.ps1, src/scripts/**/*.sh, src/scripts/completions/**, src/modules/shell.nix"
---

# Nucleus command surface

## Canonical command set

The user-facing CLI is a fixed set of ~12 flake apps, each a `nucleus-<name>` package built by `mkNucleusApps` in `src/flake.nix`. The flake `apps` output strips the `nucleus-` prefix so they run as `nix run .#<name>`:

- `apply`, `ai`, `bootstrap`, `check`, `config`, `utils`, `gc`, `svc`, `test`, `update`, `vm`, `cloud`

`service-watchdog` is a daemon-only package, NOT a nucleus app — it is not registered in `mkNucleusApps`, so it never appears on PATH, via `nix run`, or in `packages`. It runs only under systemd/launchd (`src/hosts/NixOS/activation.nix`, `src/hosts/MacBook/service-watchdog.nix`) via its store path, never as a user command. `nucleus-utils` groups user utilities; `optimize-pdf` is its first subcommand.

## No new single-purpose commands

When adding new functionality, decide in this fixed order — stop at the first tier that fits:

1. **Internal** — if the logic is not user-facing (a library, daemon helper, or activation step), keep it as a plain script invoked by other code. Do NOT register a `nucleus-*` PATH command for it. (How internal code must call other logic is governed separately by "Internal-invocation policy" below.)
2. **Subcommand** — if it is a variant or aspect of an existing nucleus app, add it as a subcommand of that parent (`check`, `gc`, `apply`, `cloud`, `update`).
3. **New nucleus app** — only if it is a genuinely independent top-level concern with no suitable parent. Register it via `nucleusApp` in `mkNucleusApps` in `src/flake.nix` (with a matching `scripts/<name>.sh` / `scripts/<name>.ps1` entry and a `home.packages` registration unless it is daemon-only like `service-watchdog`).

The command set is the coverage contract shared with the completion generators and check step `10-completions-fresh`. Adding a command without updating both breaks freshness enforcement.

## Internal-invocation policy

Internal code must NOT call `nucleus-*` PATH commands. This includes daemons, apply post-steps, scheduled tasks, and activation scripts. Invoke the underlying logic by one of:

- The **script entry**: `scripts/<name>.sh` (POSIX) or `scripts/<name>.ps1` (Windows).
- The **flake attr**: `src#<name>` (e.g. `nix run .#check`).
- A **store path**: `${nucleusApps.nucleus-<name>}/bin/nucleus-<name>` (used by `service-watchdog.nix` / `activation.nix`).

PATH commands are a user convenience surface, not an internal API. Relying on them inside the system couples activation to a user-installed profile.

## Single registration surface

All nucleus commands are declared exactly once in `mkNucleusApps` (`src/flake.nix`). The user-facing surfaces derive from it automatically:

- `home.packages` (`src/modules/shell.nix`) spreads `nucleusApps` onto PATH.
- The flake `apps` output derives via `mkNucleusAppsAsFlakeApps` (strips the `nucleus-` prefix for `nix run .#<name>`).
- The `packages` flake output spreads `nucleusApps`.

Never hand-register a command in two places. Deleting an entry from `mkNucleusApps` removes it from PATH, `nix run`, and `packages` simultaneously. This is the structural guard against the duplicate-`apps` failure mode.

## Bootstrap independence

`nucleus-bootstrap` installs Nix and base dependencies only. It MUST NOT assume anything is already provisioned. It may *optionally* invoke apply via `--apply`/`-Apply` after dependencies exist, but apply must never be a bootstrap dependency — bootstrap must succeed on a bare machine with no prior nucleus state.

## Windows provisioning runs elevated

Windows provisioning (`apply.ps1`, agent-host-shell setup, scheduled-task registration) runs self-elevated via `RunAs`, exactly like POSIX `sudo`. Writing to `%ProgramData%\nucleus\bin` (or other system-wide locations) is admin-normal and requires NO non-admin fallback path. The agent must NOT assume a non-admin case for Windows provisioning and must NOT add degraded non-privileged branches. This is the inverse-family exception already documented for `apply.ps1`; restate it explicitly so it is not forgotten.

## Windows parity

Every POSIX `scripts/<name>.sh` that exposes subcommands needs a `scripts/<name>.ps1` twin with matching `[ValidateSet(...)]` `$Action` dispatch. The two entry points must accept the same subcommand vocabulary so `nix run .#<name>` behaves identically on macOS/NixOS and Windows.

`apply` has a `scripts/apply.ps1` twin (consumed by `src/hosts/Windows/apply.ps1` for the `health-check` / `audit-store` actions), consistent with `svc` / `gc` / `cloud` / `vm` / `test` / `check`.

## Completion generators

`src/scripts/completions/gen-completions.sh` (zsh) and `gen-completions.ps1` (pwsh) are the source of truth for completions. They derive completions from each command's `--help` output. After any change to the command surface (new command, renamed subcommand, changed `[ValidateSet]`), regenerate and commit the output. Check step `10-completions-fresh` enforces freshness: it re-runs the generators in check mode and fails on any diff. Generated completion files must not be edited by hand.

## Agent-host-shell wrapper

The VS Code agent-host wrapper lives outside the user HOME:

- POSIX: `/etc/nucleus/bin/agent-host-shell` (`src/modules/agent-host-shell.nix`).
- Windows: `%ProgramData%\nucleus\bin\agent-host-shell.ps1` (`src/platforms/Windows/modules/system/Invoke-AgentHostShellSetup.ps1`).

It is a system-level provisioning artifact, not a per-user dotfile. Do not relocate it into HOME or symlink it from `src/users/`.
