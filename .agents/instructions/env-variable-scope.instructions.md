---
description: "Use when configuring environment variables across hosts. Default scope is all-process; narrower scope requires documented justification."
name: "Environment Variable Scope"
applyTo: "src/modules/**/*.nix, src/hosts/**/*.nix, src/hosts/**/*.ps1, src/hosts/Windows/**/*.yml"
---

# Environment variable scope

All env vars default to all-process scope. Narrower scope requires an inline `# WHY:` comment.

## Centralized registry

Nix vars: `src/modules/lib/env-catalog.nix` — single `catalog` attrset with `values` (per-host), `why`, optional `userSpecific`. Helpers: `allVars`, `systemVars`, `macBookAllVars`, `toJsonManifest`. PATH helpers in `src/modules/lib/managed-paths.nix`, mirroring `ManagedPaths.ps1`.

> **Invariant**: `pathComponents.prepend`/`append` are separate lists. Handle both symmetrically. Comments describe conceptual role, not current contents.

| OS | Location | Format |
| --- | --- | --- |
| macOS/NixOS | `src/modules/lib/env-catalog.nix` | Nix attrs |
| Windows (user) | `src/hosts/Windows/user/env.dsc.yml` | WinGet DSC v3 |
| Windows (system) | `src/hosts/Windows/system/env.dsc.yml` | WinGet DSC v3 |
| Windows (PATH) | `src/platforms/Windows/modules/user/Sync-UserPath.ps1` | PowerShell |

Consumers: `shell.nix` (sessionPath/sessionVariables), `src/platforms/macOS/modules/default.nix` (gui-env), `hosts/NixOS/base.nix`, `hosts/NixOS/ai.nix`, daemon files in `hosts/MacBook/`. `env/default.nix` HM module exposes `config._nucleus.envVars`. Per-host override via `override` attr. User-specific vars (`userSpecific = true`) excluded from `systemVars`, set via HM session + macOS LaunchAgent (`macBookAllVars`). Daemons consume via `resolveValue`.

Windows DSC mirrors the catalog. Parity enforced by `tests/integration/env-parity-tests.nix` + `tests/hosts/Windows/EnvVarParity.Tests.ps1`.

### Windows elevation

`nucleus-apply` self-elevates. Non-user-specific → `system/env.dsc.yml` (Machine scope). User-specific → `user/env.dsc.yml` (User scope). Elevation failure → hard-fail, no fallback.

### Adding a variable

1. **Nix**: add to `src/modules/lib/env-catalog.nix` `catalog` — set `values`, `why`, `userSpecific` as needed.
2. **Windows DSC**: `userSpecific` → `user/env.dsc.yml`; otherwise → `system/env.dsc.yml`.
3. **Tests**: verify both parity tests cover the new var.

### Cross-host exceptions

| Var | macOS | NixOS | Windows | Rationale |
| --- | --- | --- | --- | --- |
| `NUCLEUS_REPO_ROOT` | `/Library/Application Support/nucleus/repo-root` + session/GUI env | `/var/lib/nucleus/repo-root` + `environment.variables` | Machine registry via `apply.ps1` | All-process root for out-of-store symlinks + cwd-independent commands (incl. `sudo`). POSIX SYSTEM-root = parity with Windows Machine scope. |
| `NIX_SSL_CERT_FILE` | daemon env | — | — | No system CA bundle on macOS; NixOS ships `/etc/ssl/certs/ca-certificates.crt`. |
| `NUCLEUS_HOST` | daemon env | daemon env | — | Identifies host; not meaningful on Windows (different daemon model). |
| `OLLAMA_HOST` | gui-env agent | — | — | macOS: Ollama binds default port, CLI routes via LiteLLM proxy. NixOS: systemd env. |

Default: same value, same scope. Exceptions documented here.

## Scope restrictions

Valid reasons: variable causes incorrect behavior for unintended consumers (e.g. `CC`/`CXX`/`LD` on macOS — Nix LLVM paths interfere with Xcode), inherently platform-specific (`DEVELOPER_DIR` on non-macOS), or infeasible at build time (`NUCLEUS_REPO_ROOT` on NixOS — captured at eval).

"CLI-only tool" or "only shells need it" is not valid on NixOS or Windows — CLI and GUI share the same env. On macOS, `launchd` maintains separate domains; `macos-gui-env-path` bridges via `launchctl setenv` + `launchctl config user path`.
