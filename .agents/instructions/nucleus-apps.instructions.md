---
description: "Use when adding, renaming, or reviewing nucleus command-surface entries (flake apps, scripts/*.sh/.ps1, or subcommand dispatch). Covers the canonical command set, the no-new-single-purpose-command rule, internal-invocation policy, Windows parity, completion generation, and the agent-host-shell wrapper location."
name: "Nucleus Command Surface"
applyTo: "src/flake.nix, scripts/**/*.sh, scripts/**/*.ps1, src/scripts/**/*.sh, src/scripts/completions/**, src/modules/shell.nix"
---

# Nucleus command surface

## Canonical command set

12 flake apps built by `mkNucleusApps` in `src/flake.nix`. The `apps` output strips `nucleus-` prefix for `nix run .#<name>`:

- `apply`, `ai`, `bootstrap`, `check`, `config`, `utils`, `gc`, `svc`, `test`, `update`, `vm`, `cloud`

`service-watchdog` is daemon-only, NOT a nucleus app — not in `mkNucleusApps`, never on PATH or `nix run`. Runs only under systemd/launchd via store path. `nucleus-utils` groups user utilities; `optimize-pdf` is its first subcommand.

## No new single-purpose commands

When adding functionality, decide in order — stop at first fit:

1. **Internal** — not user-facing (library, daemon helper, activation step)? Keep as plain script. No `nucleus-*` PATH command.
2. **Subcommand** — variant of existing app? Add as subcommand (`check`, `gc`, `apply`, `cloud`, `update`).
3. **New app** — top-level concern with no parent? Register via `nucleusApp` in `mkNucleusApps` (matching `scripts/<name>.sh` + `scripts/<name>.ps1`; daemon-only like `service-watchdog` skips `home.packages`).

The command set is shared with completion generators and check step `10-completions-fresh`. Updating one without the other breaks freshness.

## Internal-invocation policy

Internal code must NOT call `nucleus-*` PATH commands. Invoke the underlying logic by one of:

- **Script entry**: `scripts/<name>.sh` (POSIX) or `scripts/<name>.ps1` (Windows).
- **Flake attr**: `src#<name>` (e.g. `nix run .#check`).
- **Store path**: `${nucleusApps.nucleus-<name>}/bin/nucleus-<name>` (used by `service-watchdog.nix` / `activation.nix`).

PATH commands are for users only. Internal calls couple activation to a user-installed profile.

## Single registration surface

All nucleus commands declared once in `mkNucleusApps` (`src/flake.nix`). Surfaces derive automatically:

- `home.packages` (`src/modules/shell.nix`) spreads `nucleusApps` onto PATH.
- The flake `apps` output derives via `mkNucleusAppsAsFlakeApps` (strips `nucleus-` prefix for `nix run .#<name>`).
- The `packages` flake output spreads `nucleusApps`.

Never hand-register in two places. Deleting from `mkNucleusApps` removes from PATH, `nix run`, and `packages` simultaneously.

## Bootstrap independence

`nucleus-bootstrap` installs Nix and base deps only. Must not assume prior state. May invoke apply via `--apply`/`-Apply` after deps exist, but apply must never be a bootstrap dependency — bootstrap succeeds on a bare machine.

## Windows provisioning runs elevated

Windows provisioning runs self-elevated via `RunAs`. Writing to `%ProgramData%\nucleus\bin` is admin-normal, no non-admin fallback. The agent must not assume non-admin or add degraded branches. Inverse-family exception per `apply.ps1`.

## Windows parity

Every POSIX `scripts/<name>.sh` with subcommands needs a `scripts/<name>.ps1` twin with matching `[ValidateSet(...)]` `$Action` dispatch. Same subcommand vocabulary on all platforms.

`apply` has a `scripts/apply.ps1` twin (consumed by `src/hosts/Windows/apply.ps1` for `health-check`/`audit-store`), consistent with `svc`/`gc`/`cloud`/`vm`/`test`/`check`.

## Completion generators

`src/scripts/completions/gen-completions.sh` (zsh) and `gen-completions.ps1` (pwsh) derive completions from `--help` output. After command-surface changes: regenerate and commit. Check step `10-completions-fresh` re-runs in check mode, fails on diff. Never edit generated files by hand.

## Agent-host-shell wrapper

VS Code agent-host wrapper, outside user HOME:
- POSIX: SYSTEM root bin — macOS `/Library/Application Support/nucleus/bin/agent-host-shell`, NixOS `/var/lib/nucleus/bin/agent-host-shell` (`src/modules/agent-host-shell.nix`).
- Windows: `%ProgramData%\nucleus\bin\agent-host-shell.ps1` (`src/platforms/Windows/modules/system/Invoke-AgentHostShellSetup.ps1`).

System-level provisioning, not per-user. Do not relocate into HOME or symlink from `src/users/`.
