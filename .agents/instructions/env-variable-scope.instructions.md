---
description: "Use when configuring environment variables across hosts. Default scope is all-process; narrower scope requires documented justification."
name: "Environment Variable Scope"
applyTo: "src/modules/**/*.nix, src/hosts/**/*.nix, src/hosts/**/*.ps1, src/hosts/Windows/**/*.yml"
---

# Environment variable scope

Every environment variable set by this repo must default to all-process availability on the host. Restricting scope (shell-only, service-only) is an exception requiring an inline `# WHY:` comment.

## Centralized registry

All Nix-side env vars are declared in `src/modules/lib/env-catalog.nix`. The catalog entries specify value, allowed hosts, and rationale. Helper functions (`allVars`, `systemVars`, `macBookAllVars`) consume the catalog into host-specific formats.

### Registry locations

| OS      | Location                                                        | Format        |
| ------- | --------------------------------------------------------------- | ------------- |
| macOS   | `src/modules/lib/env-catalog.nix` (catalog)                     | Nix attrs     |
| NixOS   | `src/modules/lib/env-catalog.nix` (catalog)                     | Nix attrs     |
| Windows | `src/hosts/Windows/user/env.dsc.yml` (user-specific vars)       | WinGet DSC v3 |
| Windows | `src/hosts/Windows/system/env.dsc.yml` (non-user-specific vars) | WinGet DSC v3 |
| Windows | `src/platforms/Windows/modules/user/Sync-UserPath.ps1` (PATH)       | PowerShell    |

**Nix-side registry** (`src/modules/lib/env-catalog.nix`):

- Declares every var in a single `catalog` attrset with `values` (per-host attrset: `default`, `MacBook`, `NixOS`, `Windows`), `why`, and optional `userSpecific`.
- Pure helper functions (`allVars`, `systemVars`, `macBookAllVars`, `toJsonManifest`) transform the catalog into host-specific formats.
- Managed PATH components and helpers (`pathComponents`, `toShellPrependPath`, `toShellAppendPath`, `toPowerShellPrependSnippet`, `toPowerShellAppendSnippet`) live in `src/modules/lib/managed-paths.nix`, mirroring `ManagedPaths.ps1` on Windows.
  > **Invariant**: `pathComponents.prepend` and `pathComponents.append` are always declared as separate lists. Consumers MUST handle both symmetrically — never assume either is empty. Comments MUST describe the conceptual role (before-system-default vs. after-system-default), not the current contents.
- Daemon env var consumption uses `resolveValue` directly in each daemon file.
- Consumed by: `shell.nix` (via `home.sessionPath`, `home.sessionVariables`), `src/platforms/macOS/modules/default.nix` (gui-env LaunchAgent, macos-gui-env-path activation), `hosts/NixOS/base.nix`, `hosts/NixOS/ai.nix`, and daemon files in `hosts/MacBook/`.
- The `env/default.nix` Home Manager module exposes `config._nucleus.envVars` for introspection.
- **Overriding per host**: use the `override` attr in the catalog entry (e.g., NixOS vs macOS vs Windows).
- **User-specific vars**: set `userSpecific = true` in the catalog entry for vars whose value depends on the logged-in user (e.g. `PASSWORD_STORE_DIR`). These are excluded from `systemVars` (system-wide env) and only set via home-manager session variables and the macOS LaunchAgent (`macBookAllVars`).

**Windows parallel registry** (WinGet DSC v3):

- `src/hosts/Windows/user/env.dsc.yml` — user-specific vars (User scope).
- `src/hosts/Windows/system/env.dsc.yml` — non-user-specific vars (Machine scope).
- Manually maintained as WinGet DSC resources.
- Must mirror the Nix catalog's Windows-relevant vars. Parity is enforced by automated tests: `tests/integration/env-parity-tests.nix` generates a JSON manifest from the catalog; `tests/hosts/Windows/EnvVarParity.Tests.ps1` checks the DSC entries against it.

### Windows elevation policy

`nucleus-apply` self-elevates (UAC admin) before any configuration step. Machine-scope (HKLM) writes are therefore always accessible. All non-user-specific environment variables live at Machine scope in `system/env.dsc.yml`. User-specific variables (home-directory dependent) live at User scope in `user/env.dsc.yml`. If elevation fails, `apply.ps1` must hard-fail — there is no fallback to User scope.

### Adding a new variable

1. **Nix-side catalog**: add an entry in `src/modules/lib/env-catalog.nix` `catalog` attrset.
   - Set `values = { default = ...; MacBook = ...; NixOS = ...; Windows = ...; }`, `why`.
   - Use `values.default` for the primary value, per-host keys for host-specific overrides.
   - If the value depends on the logged-in user, set `userSpecific = true`.
2. **Windows DSC**: if the var applies to Windows:
   - If `userSpecific = true`, add a DSC `Environment` resource in `src/hosts/Windows/user/env.dsc.yml` (User scope).
   - Otherwise, add the resource in `src/hosts/Windows/system/env.dsc.yml` (Machine scope).
3. **Tests**: ensure the parity test covers the new var:
   - `tests/integration/env-parity-tests.nix` generates a JSON manifest from the catalog.
   - `tests/hosts/Windows/EnvVarParity.Tests.ps1` reads the manifest and checks the DSC entries.

### Cross-host special-case policy

Some environment variables need different treatment per OS — this table documents the exceptions and why they exist.

| Var                 | macOS         | NixOS      | Windows | Rationale                                                                                                                           |
| ------------------- | ------------- | ---------- | ------- | ----------------------------------------------------------------------------------------------------------------------------------- |
| `NUCLEUS_REPO_ROOT` | `/etc/nucleus/repo-root` + session/GUI env | `/etc/nucleus/repo-root` + `environment.variables` | Machine registry via `apply.ps1` | All-process repo root for out-of-store symlinks and cwd-independent `nucleus-*` commands (including under `sudo`). POSIX `/etc` file is parity with Windows Machine scope. |
| `NIX_SSL_CERT_FILE` | daemon env    | —          | —       | macOS has no system CA bundle in a standard location; NixOS ships `/etc/ssl/certs/ca-certificates.crt` in the system profile.       |
| `NUCLEUS_HOST`      | daemon env    | daemon env | —       | Identifies which host the daemon runs on; not meaningful on Windows since daemons are managed differently.                          |
| `OLLAMA_HOST`       | gui-env agent | —          | —       | macOS Ollama daemon binds to default port; CLI clients route through LiteLLM proxy via gui-env. NixOS uses the systemd service env. |

The principle: **same value, same scope** is the default. When a var must have different treatment (excluded from a host, different scope, etc.), document it here with an explicit why.

## Scope restrictions

Valid reasons to restrict scope:

- The variable would cause incorrect behavior for unintended consumers (e.g., `CC`/`CXX`/`LD` on macOS — Nix LLVM paths in GUI process env interfere with Xcode toolchain discovery).
- The concept is inherently platform-specific (e.g., `DEVELOPER_DIR` on non-macOS hosts).
- The value is technically infeasible to compute at build time (e.g., `NUCLEUS_REPO_ROOT` on NixOS — captured at eval time).

"CLI-only tool" or "only shells need it" is not a valid restriction on NixOS or Windows — both CLI and GUI processes inherit the same environment. On macOS, `launchd` maintains separate shell and GUI domains. The `macos-gui-env-path` activation step bridges this by calling `launchctl setenv` for all managed vars and `launchctl config user path` for LaunchServices PATH; a one-shot LaunchAgent covers login-time gaps.
