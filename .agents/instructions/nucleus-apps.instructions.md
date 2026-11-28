---
description: "Use when adding, renaming, or reviewing nucleus command-surface entries (flake apps, scripts/*.sh/.ps1, or subcommand dispatch). Covers the canonical command set, the no-new-single-purpose-command rule, internal-invocation policy, Windows parity, completion generation, and the agent-host-shell wrapper location."
name: "Nucleus Command Surface"
applyTo: "src/flake.nix, scripts/**/*.sh, scripts/**/*.ps1, src/scripts/**/*.sh, src/scripts/completions/**, src/modules/shell/default.nix"
---

# Nucleus command surface

Declare every `nucleus-*` command once in `mkNucleusApps` (`src/flake.nix`); PATH, `nix run`, and `packages` derive from it. The `apps` output strips the `nucleus-` prefix. `service-watchdog` stays out (daemon, store path only); `nucleus-utils` groups utilities; `camilladsp-heartbeat` is registered despite being a daemon because operators run `--probe`.

Adding functionality: keep non-user-facing work as a plain script, add a subcommand to an existing app, or register a new top-level app with paired `.sh`/`.ps1`. An entry with no Windows twin declares only POSIX and its completion. Internal code never calls a `nucleus-*` PATH command; use the script entry, flake attr, or store path.

`src/modules/completions/nucleus-apps.json` is generated from `mkNucleusApps`; regenerate manifest and completions in the same change and never hand-edit generated files. `nucleus-bootstrap` installs deps only and may call apply after. Windows self-elevates for `%ProgramData%\nucleus\bin`. Every POSIX command with subcommands needs a `.ps1` twin with matching `$Action`. The VS Code agent host wrapper is system-level, never per-user.

Details: `src/users/default/agents/skills/nucleus-platform-reference/references/nucleus-apps.md`.
