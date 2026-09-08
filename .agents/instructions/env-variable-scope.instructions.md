---
description: "Use when configuring environment variables across hosts. Default scope is all-process; narrower scope requires documented justification."
name: "Environment Variable Scope"
applyTo: "src/modules/**/*.nix, src/hosts/**/*.nix, src/hosts/**/*.ps1, src/hosts/Windows/**/*.yml"
---

# Environment variable scope

All env vars default to all-process scope. Narrower scope requires an inline `# WHY:` comment.

## Centralized registry

Nix vars: `src/modules/lib/env-catalog.nix` — `catalog` attrset with `values` (per-host), `why`, optional `userSpecific`. Helpers: `allVars`, `systemVars`, `macBookAllVars`, `toJsonManifest`. PATH helpers in `src/modules/lib/managed-paths.nix`.

> **Invariant**: `pathComponents.prepend`/`append` are separate lists. Handle both symmetrically.

| OS | Location | Format |
| --- | --- | --- |
| macOS/NixOS | `src/modules/lib/env-catalog.nix` | Nix attrs |
| Windows | `src/hosts/Windows/{user,system}/env.dsc.yml` | WinGet DSC v3 |
| Windows PATH | `src/platforms/Windows/modules/user/Sync-UserPath.ps1` | PowerShell |

Consumers: `shell.nix`, macOS `default.nix`, `hosts/NixOS/{base,ai}.nix`, daemon files in `hosts/MacBook/`. `env/default.nix` exposes `config._nucleus.envVars`. Per-host override via `override` attr. User-specific vars excluded from `systemVars`. Windows DSC mirrors catalog; parity enforced by `tests/integration/env-parity-tests.nix` + `tests/hosts/Windows/EnvVarParity.Tests.ps1`.

### Windows elevation

`nucleus-apply` self-elevates. Non-user-specific → `system/env.dsc.yml` (Machine scope). User-specific → `user/env.dsc.yml` (User scope). Elevation failure → hard-fail, no fallback.

### Adding a variable

Nix: add to `src/modules/lib/env-catalog.nix` `catalog`. Windows DSC: `userSpecific` → `user/env.dsc.yml`, else → `system/env.dsc.yml`. Tests: verify parity tests cover the new var.

### Cross-host exceptions

| Var | macOS | NixOS | Windows | Rationale |
| --- | --- | --- | --- | --- |
| `NUCLEUS_REPO_ROOT` | `/Library/Application Support/nucleus/repo-root` + session/GUI env | `/var/lib/nucleus/repo-root` + `environment.variables` | Machine registry via `apply.ps1` | All-process root for out-of-store symlinks + cwd-independent commands. POSIX = parity with Windows Machine scope. |
| `NIX_SSL_CERT_FILE` | daemon env | — | — | No system CA bundle on macOS. |
| `NUCLEUS_HOST` | daemon env | daemon env | — | Not meaningful on Windows. |
| `OLLAMA_HOST` | gui-env agent | — | — | CLI routes via LiteLLM proxy. |

Default: same value, same scope. Exceptions here.

## Scope restrictions

Valid: incorrect behavior for unintended consumers (`CC`/`CXX`/`LD` on macOS), platform-specific (`DEVELOPER_DIR` on non-macOS), infeasible at build time (`NUCLEUS_REPO_ROOT` on NixOS). "CLI-only" not valid on NixOS/Windows. macOS: `launchd` separate domains, bridged by `macos-gui-env-path`.
