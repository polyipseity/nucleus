---
description: "Use when configuring environment variables across hosts. Default scope is all-process; narrower scope requires documented justification."
name: "Environment Variable Scope"
applyTo: "src/modules/**/*.nix, src/hosts/**/*.nix, src/hosts/**/*.ps1, src/hosts/Windows/**/*.yml"
---

# Environment variable scope

All env vars default to all-process scope. Narrower scope requires an inline `# WHY:` comment.

## Centralized registry

Nix vars: `src/modules/lib/env-secrets.nix` — `catalog` attrset with `values` (per-host), `why`, optional `userSpecific`. Helpers: `allVars`, `systemVars`, `macBookAllVars`, `toJsonManifest`. PATH helpers in `src/modules/lib/managed-paths.nix`.

> **Invariant**: `pathComponents.prepend`/`append` are separate lists. Handle both symmetrically.

| OS | Location | Format |
| --- | --- | --- |
| macOS/NixOS | `src/modules/lib/env-secrets.nix` | Nix attrs |
| Windows | `src/hosts/Windows/{user,system}/env.dsc.yml` | WinGet DSC v3 |
| Windows PATH | `src/platforms/Windows/modules/user/Sync-UserPath.ps1` | PowerShell |

Consumers: `shell.nix`, macOS `default.nix`, `hosts/NixOS/{base,ai}.nix`, daemon files in `hosts/MacBook/`. `env/default.nix` exposes `config._nucleus.envVars`. Per-host override via `override` attr. User-specific vars excluded from `systemVars`. Windows DSC mirrors catalog; parity enforced by `tests/integration/env-parity-tests.nix` (catalog ↔ DSC scope split, Nix lane) + `tests/platforms/Windows/modules/EnvVarParity.Tests.ps1` (Windows-only wiring, Pester).

### Per-shell and GUI delivery

The catalog is the single source of truth for any value that must reach more than one surface, and it already feeds all three: POSIX shells read `allVars` through Home Manager session variables, macOS GUI-launched processes read `macBookAllVars` through the `gui-env` agent (`launchctl setenv`), and PowerShell reads the value substituted into its profile by `src/modules/pwsh.nix` (`init.ps1`) or `Sync-ShellProfile.ps1` (Windows).

A framework export that reaches one shell family is not enough: nix-darwin exports the GPG agent environment for zsh/bash/fish only, from the snippet it sources in `/etc/zshenv`, so a PowerShell started outside a zsh parent has no `SSH_AUTH_SOCK` and falls back to an `IdentityFile` it cannot read. A value a provisioned shell or GUI process needs therefore belongs in the catalog, or the uncovered surface needs an inline `# WHY:` explaining why it does not.

An entry keyed to a single host resolves to null on other hosts; consumers guard on that instead of substituting a default, so a host that manages no such value keeps whatever its session environment provides.

### Windows elevation

`nucleus-apply` self-elevates. Non-user-specific → `system/env.dsc.yml` (Machine scope). User-specific → `user/env.dsc.yml` (User scope). Elevation failure → hard-fail, no fallback.

### Adding a variable

Nix: add to `src/modules/lib/env-secrets.nix` `catalog`. Windows DSC: `userSpecific` → `user/env.dsc.yml`, else → `system/env.dsc.yml`. Tests: verify parity tests cover the new var.

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
