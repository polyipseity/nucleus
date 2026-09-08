---
description: "Use when configuring environment variables across hosts. Default scope is all-process; narrower scope requires documented justification."
name: "Environment Variable Scope"
applyTo: "src/modules/**/*.nix, src/hosts/**/*.nix, src/hosts/**/*.ps1, src/hosts/Windows/**/*.yml"
---

# Environment variable scope

All env vars default to all-process scope. Narrower scope (shell-only, service-only) requires an inline `# WHY:` comment.

## Centralized registry

Nix-side vars live in `src/modules/lib/env-catalog.nix` — a single `catalog` attrset with `values` (per-host: `default`/`MacBook`/`NixOS`/`Windows`), `why`, and optional `userSpecific`. Helpers (`allVars`, `systemVars`, `macBookAllVars`, `toJsonManifest`) transform it to host-specific formats.

PATH helpers (`pathComponents`, `toShellPrependPath`, `toShellAppendPath`, `toPowerShellPrependSnippet`, `toPowerShellAppendSnippet`) live in `src/modules/lib/managed-paths.nix`, mirroring `ManagedPaths.ps1` on Windows.

> **Invariant**: `pathComponents.prepend` and `pathComponents.append` are separate lists. Consumers handle both symmetrically — never assume either is empty. Comments describe conceptual role (before-system-default vs. after-system-default), not current contents.

Registry locations:

| OS | Location | Format |
| ------- | --------------------------------------------------------------- | ------------- |
| macOS/NixOS | `src/modules/lib/env-catalog.nix` | Nix attrs |
| Windows (user) | `src/hosts/Windows/user/env.dsc.yml` | WinGet DSC v3 |
| Windows (system) | `src/hosts/Windows/system/env.dsc.yml` | WinGet DSC v3 |
| Windows (PATH) | `src/platforms/Windows/modules/user/Sync-UserPath.ps1` | PowerShell |

Consumers: `shell.nix` (`home.sessionPath`/`home.sessionVariables`), `src/platforms/macOS/modules/default.nix` (gui-env LaunchAgent), `hosts/NixOS/base.nix`, `hosts/NixOS/ai.nix`, daemon files in `hosts/MacBook/`. The `env/default.nix` HM module exposes `config._nucleus.envVars` for introspection. Per-host override: use the `override` attr. User-specific vars (`userSpecific = true`) are excluded from `systemVars` and set only via HM session variables and the macOS LaunchAgent (`macBookAllVars`).

Daemon consumption uses `resolveValue` directly in each daemon file.

Windows DSC mirrors the Nix catalog. Parity enforced by `tests/integration/env-parity-tests.nix` (JSON manifest) checked by `tests/hosts/Windows/EnvVarParity.Tests.ps1`.

### Windows elevation policy

`nucleus-apply` self-elevates (UAC admin). Machine-scope (HKLM) writes are always accessible. Non-user-specific vars → `system/env.dsc.yml` (Machine scope). User-specific vars → `user/env.dsc.yml` (User scope). Elevation failure → hard-fail, no fallback to User scope.

### Adding a new variable

1. **Nix catalog**: add entry in `src/modules/lib/env-catalog.nix` `catalog` — set `values`, `why`, `userSpecific` as needed.
2. **Windows DSC**: `userSpecific` → `user/env.dsc.yml` (User scope); otherwise → `system/env.dsc.yml` (Machine scope).
3. **Tests**: verify `tests/integration/env-parity-tests.nix` and `tests/hosts/Windows/EnvVarParity.Tests.ps1` cover the new var.

### Cross-host special-case policy

| Var | macOS | NixOS | Windows | Rationale |
| ------------------- | ------------- | ---------- | ------- | ----------------------------------------------------------------------------------------------------------------------------------- |
| `NUCLEUS_REPO_ROOT` | `/Library/Application Support/nucleus/repo-root` + session/GUI env | `/var/lib/nucleus/repo-root` + `environment.variables` | Machine registry via `apply.ps1` | All-process repo root for out-of-store symlinks and cwd-independent `nucleus-*` commands (including under `sudo`). POSIX SYSTEM-root file is parity with Windows Machine scope. |
| `NIX_SSL_CERT_FILE` | daemon env | — | — | macOS has no system CA bundle in a standard location; NixOS ships `/etc/ssl/certs/ca-certificates.crt` in the system profile. |
| `NUCLEUS_HOST` | daemon env | daemon env | — | Identifies which host the daemon runs on; not meaningful on Windows since daemons are managed differently. |
| `OLLAMA_HOST` | gui-env agent | — | — | macOS Ollama daemon binds to default port; CLI clients route through LiteLLM proxy via gui-env. NixOS uses the systemd service env. |

Default: **same value, same scope**. Different treatment → document with explicit why here.

## Scope restrictions

Valid reasons to restrict scope:

- Variable causes incorrect behavior for unintended consumers (e.g., `CC`/`CXX`/`LD` on macOS — Nix LLVM paths in GUI process env interfere with Xcode toolchain discovery).
- Inherently platform-specific (e.g., `DEVELOPER_DIR` on non-macOS hosts).
- Infeasible to compute at build time (e.g., `NUCLEUS_REPO_ROOT` on NixOS — captured at eval time).

"CLI-only tool" or "only shells need it" is not valid on NixOS or Windows — both CLI and GUI inherit the same env. On macOS, `launchd` maintains separate shell/GUI domains. `macos-gui-env-path` bridges this via `launchctl setenv` for managed vars and `launchctl config user path` for LaunchServices PATH; a one-shot LaunchAgent covers login-time gaps.
