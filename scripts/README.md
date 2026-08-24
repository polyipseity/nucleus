# Scripts

This directory holds the user-facing `nucleus-*` command entry points. Every `nucleus-*` command is a nucleus app, and each app is a paired `.sh` (POSIX) and `.ps1` (Windows) entry point kept in lockstep. The only files here that are not app entry points are non-app resource/config files and this README.

## Cross-platform parity

Each nucleus app ships both a `.sh` and a `.ps1` twin. The `.sh` runs on POSIX hosts (macOS, NixOS); the `.ps1` runs on Windows. The two are maintained in lockstep so the same command surface exists on every platform. The exceptions are non-app resource/config files: `bootstrap-versions.env` (shared tool version pins for bootstrap), the `*.PSScriptAnalyzerSettings.psd1` settings files (consumed by `check pwsh`), and `prek-hooks.py` (pre-commit hook helper).

## `nucleus-*` commands

The flake wraps each paired `.sh` / `.ps1` pair as `nucleus-<name>` (for example `nucleus-gc` → `scripts/gc.sh` + `scripts/gc.ps1`). The one exception is `nucleus-apply`: its POSIX entry point lives at `src/scripts/apply.sh`, with its Windows twin at `scripts/apply.ps1`. `nucleus-utils` groups user utilities; `gs-pdf-opt` is its first subcommand (run as `nucleus-utils gs-pdf-opt`).

| App | POSIX | Windows |
|-----|-------|---------|
| `nucleus-ai` | `scripts/ai.sh` | `scripts/ai.ps1` |
| `nucleus-apply` | `src/scripts/apply.sh` | `scripts/apply.ps1` |
| `nucleus-bootstrap` | `scripts/bootstrap.sh` | `scripts/bootstrap.ps1` |
| `nucleus-check` | `scripts/check.sh` | `scripts/check.ps1` |
| `nucleus-cloud` | `scripts/cloud.sh` | `scripts/cloud.ps1` |
| `nucleus-config` | `scripts/config.sh` | `scripts/config.ps1` |
| `nucleus-gc` | `scripts/gc.sh` | `scripts/gc.ps1` |
| `nucleus-utils` | `scripts/utils.sh` | `scripts/utils.ps1` |
| `nucleus-svc` | `scripts/svc.sh` | `scripts/svc.ps1` |
| `nucleus-test` | `scripts/test.sh` | `scripts/test.ps1` |
| `nucleus-update` | `scripts/update.sh` | `scripts/update.ps1` |
| `nucleus-vm` | `scripts/vm.sh` | `scripts/vm.ps1` |

Wrappers bundle both trees so commands work from a dev checkout or an installed profile.

## Orchestrators

`check.sh` / `check.ps1` and `test.sh` / `test.ps1` are thin drivers. They load frameworks from `src/scripts/checks/` and `src/scripts/tests/` and auto-discover steps. The PowerShell lint path (`check pwsh`) is inlined into `check` and lives at `src/scripts/checks/check-pwsh.ps1`.

Most shell scripts here source `src/scripts/lib/lib.sh` for `derive_repo_root`, usage helpers, and host detection (`resolve_nucleus_host`).

## vs `src/scripts/`

| | `scripts/` (here) | `src/scripts/` |
|--|-------------------|----------------|
| Who runs it | You, CI, post-apply hooks | Nix activation, systemd/launchd, internal callers |
| Layout | Flat at repo root | Subdirs by domain (`services/`, `lib/`, `checks/`, …) |

If a script becomes part of activation or a long-running service, it usually moves under `src/scripts/`. Internal dev tooling that is not a user-facing `nucleus-*` command also lives under `src/scripts/` (e.g. the completion generators in `src/scripts/completions/`).

## Cross-links

- Declarative tree: [src/README.md](../src/README.md)
- User config merge rules: [src/users/README.md](../src/users/README.md)
- Apply flows: [README.md](../README.md)
