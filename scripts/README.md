# Scripts

This directory holds contributor and operator commands. They are paired `.sh` / `.ps1` entry points unless the task is inherently single-platform.

## vs `src/scripts/`

| | `scripts/` (here) | `src/scripts/` |
|--|-------------------|----------------|
| Who runs it | You, CI, post-apply hooks | Nix activation, systemd/launchd, internal callers |
| Layout | Flat at repo root | Subdirs by domain (`services/`, `lib/`, `checks/`, …) |

If a script becomes part of activation or a long-running service, it usually moves under `src/scripts/`.

## `nucleus-*` commands

The flake wraps most of this directory as `nucleus-<name>` (for example `nucleus-gc` → `scripts/gc.sh`). Exceptions:

- `nucleus-apply` → `src/scripts/apply.sh`
- `nucleus-service-watchdog` → `src/scripts/services/service-watchdog.sh`

Wrappers bundle both trees so commands work from a dev checkout or an installed profile.

## Orchestrators

`check.sh` / `check.ps1` and `test.sh` / `test.ps1` are thin drivers. They load frameworks from `src/scripts/checks/` and `src/scripts/tests/` and auto-discover steps.

Most shell scripts here source `src/scripts/lib/lib.sh` for `derive_repo_root`, usage helpers, and host detection (`resolve_nucleus_host`).

## Intentional unpaired files

- `check-sh.sh` — shell lint only
- `check-pwsh.ps1` — PowerShell lint only
- `prek-hooks.py` — pre-commit hook helper
- `bootstrap-versions.env` — shared tool version pins for bootstrap

## Cross-links

- Declarative tree: [src/README.md](../src/README.md)
- User config merge rules: [src/users/README.md](../src/users/README.md)
- Apply flows: [README.md](../README.md)
