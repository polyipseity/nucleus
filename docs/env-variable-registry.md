# Environment variable registry

The canonical list of every managed environment variable lives in
`src/modules/lib/env-vars.nix` (the `catalog` attrset). **This file is the
single source of truth** — the table below would duplicate it and go stale.
Refer to `env-vars.nix` directly for the current variable list, values, scope,
and OS-specific overrides.

The catalog exposes helpers that transform entries into platform-specific
formats (LaunchAgent scripts, NixOS system env, DSC entries, etc.). A JSON
manifest for external consumption is also available via `toJsonManifest`.

## Registry locations

| OS      | Location                                                        | Format         |
| ------- | --------------------------------------------------------------- | -------------- |
| macOS   | `src/modules/lib/env-vars.nix` (catalog)                        | Nix attrs      |
| NixOS   | `src/modules/lib/env-vars.nix` (catalog)                        | Nix attrs      |
| Windows | `src/hosts/Windows/user/env.dsc.yml` (user-specific vars)       | WinGet DSC v3  |
| Windows | `src/hosts/Windows/system/env.dsc.yml` (non-user-specific vars) | WinGet DSC v3  |
| Windows | `src/hosts/Windows/modules/user/Sync-UserPath.ps1` (PATH)       | PowerShell     |

**Nix-side registry** (`src/modules/lib/env-vars.nix`):

- Declares every var in a single `catalog` attrset with `values` (per-OS attrset: `default`, `macOS`, `NixOS`, `Windows`), `why`, optional `userSpecific` (per-user), optional `excludeFromLaunchctl`, and optional `scope` (defaults to `"all-process"`; set explicitly only for `"shell-only"`).
- Pure helper functions (`toHomeSessionVariables`, `toNixOSSystemEnvironment`, `toLaunchctlScript`, `toNixOSServiceEnv`, `toMacOSDaemonOllamaEnv`) transform the catalog into platform-specific formats.
- Consumed by: `home.nix`, `shell.nix`, `macos.nix` (LaunchAgent), `hosts/NixOS/base.nix`, `hosts/NixOS/ai.nix`.
- The `env/default.nix` Home Manager module exposes `config._nucleus.envVars` for introspection.

**Windows parallel registry** (WinGet DSC v3):

- `src/hosts/Windows/user/env.dsc.yml` — user-specific vars (User scope).
- `src/hosts/Windows/system/env.dsc.yml` — non-user-specific vars (Machine scope).
- Manually maintained as WinGet DSC resources.
- Must mirror the Nix catalog's Windows-relevant vars. Parity is enforced by automated tests: `tests/integration/env-parity-tests.nix` generates a JSON manifest from the catalog; `tests/hosts/Windows/EnvVarParity.Tests.ps1` checks the DSC entries against it.

### Windows elevation policy

`nucleus-apply` self-elevates (UAC admin) before any configuration step.
Machine-scope (HKLM) writes are therefore always accessible. All
non-user-specific environment variables live at Machine scope in
`system/env.dsc.yml`. User-specific variables (home-directory dependent)
live at User scope in `user/env.dsc.yml`. If elevation fails, `apply.ps1`
must hard-fail — there is no fallback to User scope.

## Adding a new variable

1. **Nix-side catalog**: add an entry in `src/modules/lib/env-vars.nix` `catalog` attrset.
   - Set `values = { default = ...; macOS = ...; NixOS = ...; Windows = ...; }`, `why`.
   - Use `values.default` for the primary value, per-OS keys for OS-specific overrides.
   - If the value depends on the logged-in user, set `userSpecific = true`.
   - If the var should be excluded from launchd, set `excludeFromLaunchctl = true`.
   - `scope` defaults to `"all-process"`. Only set explicitly for `"shell-only"`.
2. **Windows DSC**: if the var applies to Windows:
   - If `userSpecific = true`, add a DSC `Environment` resource in `src/hosts/Windows/user/env.dsc.yml` (User scope).
   - Otherwise, add the resource in `src/hosts/Windows/system/env.dsc.yml` (Machine scope).
3. **Tests**: ensure the parity test covers the new var:
   - `tests/integration/env-parity-tests.nix` generates a JSON manifest from the catalog.
   - `tests/hosts/Windows/EnvVarParity.Tests.ps1` reads the manifest and checks the DSC entries.
