# Environment variable registry

This document is the cross-reference between the Nix-side centralized registry and the Windows parallel registry.

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
- Pure helper functions (`toHomeSessionVariables`, `toNixOSSystemEnvironment`, `toLaunchctlScript`, `toNixOSServiceEnv`) transform the catalog into platform-specific formats.
- Consumed by: `home.nix`, `shell.nix`, `macos.nix` (LaunchAgent), `hosts/NixOS/base.nix`, `hosts/NixOS/ai.nix`.
- The `env/default.nix` Home Manager module exposes `config._nucleus.envVars` for introspection.

**Windows parallel registry** (WinGet DSC v3):

- `src/hosts/Windows/user/env.dsc.yml` — user-specific vars (User scope).
- `src/hosts/Windows/system/env.dsc.yml` — non-user-specific vars (Machine scope).
- Manually maintained as WinGet DSC resources.
- Must mirror the Nix catalog's Windows-relevant vars. Parity is enforced by automated tests (see below).

### Windows elevation policy

`nucleus-apply` self-elevates (UAC admin) before any configuration step.
Machine-scope (HKLM) writes are therefore always accessible. All
non-user-specific environment variables live at Machine scope in
`system/env.dsc.yml`. User-specific variables (home-directory dependent)
live at User scope in `user/env.dsc.yml`. If elevation fails, `apply.ps1`
must hard-fail — there is no fallback to User scope.

## Managed variables

| Variable                   | Scope        | User-specific | Nix                    | Windows (DSC)                          | Notes                                                  |
| -------------------------- | ------------ | ------------- | ---------------------- | -------------------------------------- | ------------------------------------------------------ |
| `EDITOR`                   | all-process  | no            | null (set by neovim)   | `nvim` (`system/env.dsc.yml`)          | macOS LaunchAgent hardcodes `nvim`; Windows: Machine scope via `system/env.dsc.yml` |
| `VISUAL`                   | all-process  | no            | null (set by neovim)   | `nvim` (`system/env.dsc.yml`)          | macOS LaunchAgent hardcodes `nvim`; Windows: Machine scope via `system/env.dsc.yml` |
| `CC`                       | all-process  | no            | LLVM clang store path  | `clang` (`system/env.dsc.yml`)         | macOS/NixOS: all-process (set in Nix catalog + GUI domain). Windows: all-process via Machine-scope DSC (`system/env.dsc.yml`; resolved from PATH at process creation) |
| `CXX`                      | all-process  | no            | LLVM clang++ store path| `clang++` (`system/env.dsc.yml`)       | same as CC                                              |
| `LD`                       | all-process  | no            | LLVM lld store path    | `ld.lld` (`system/env.dsc.yml`)        | same as CC                                              |
| `DEVELOPER_DIR`            | all-process  | no            | Nix apple-sdk path     | —                                      | macOS only                                              |
| `SDKROOT`                  | all-process  | no            | macOS SDK path         | —                                      | macOS only                                              |
| `LIBRARY_PATH`             | all-process  | no            | libiconv store path    | —                                      | macOS only                                              |
| `NIX_SSL_CERT_FILE`        | all-process  | no            | cacert bundle path     | —                                      | macOS + NixOS. Windows intentionally absent — Nix upstream uses CURLSSLOPT_NATIVE_CA (Windows native cert store) instead of a file-based CA bundle. |
| `OPENCODE_DISABLE_AUTOUPDATE`| all-process| no           | `true`                 | `true` (`system/env.dsc.yml`)          | —                                                      |
| `OLLAMA_HOST`              | all-process  | no            | `127.0.0.1:4000`       | `127.0.0.1:4000` (`system/env.dsc.yml`) | —                                                      |
| `OLLAMA_FLASH_ATTENTION`   | all-process  | no            | `1`                    | `1` (`system/env.dsc.yml`)             | —                                                      |
| `OLLAMA_CONTEXT_LENGTH`    | all-process  | no            | `32768`                | `32768` (`system/env.dsc.yml`)         | —                                                      |
| `OLLAMA_KV_CACHE_TYPE`     | all-process  | no            | `q4_0`                 | `q4_0` (`system/env.dsc.yml`)          | —                                                      |
| `PASSWORD_STORE_DIR`       | all-process  | yes           | per-user path          | `%USERPROFILE%\dev\...`                | —                                                      |
| `GOPASS_CONFIG_COUNT`      | all-process  | yes           | `1`                    | `1`                                    | —                                                      |
| `GOPASS_CONFIG_KEY_1`      | all-process  | yes           | `path`                 | `path`                                 | —                                                      |
| `GOPASS_CONFIG_VALUE_1`    | all-process  | yes           | per-user path          | `%USERPROFILE%\dev\...`                | —                                                      |
| `NUCLEUS_DEFAULT_DEV_BIN`  | all-process  | yes           | defaultDevTools path   | `%USERPROFILE%\scoop\shims`            | Platform-appropriate fallback toolchain path           |
| `NUCLEUS_DEFAULT_DEV_ENV`  | all-process  | yes           | `1`                    | `1`                                    | —                                                      |
| `NUCLEUS_HOST`             | all-process  | no            | `MacBook` / `NixOS`    | `Windows` (`system/env.dsc.yml`)       | Per-OS identity. Windows set via DSC at Machine scope; apply.ps1 also sets process-level for subprocess visibility. |
| `NUCLEUS_REPO_ROOT`        | all-process  | no            | eval-time env var      | —                                      | macOS only (apply.sh export)                           |
| `STARSHIP_CACHE`           | all-process  | yes           | `~/.cache/starship`    | `%USERPROFILE%\.cache\starship`        | —                                                      |
| `STARSHIP_CONFIG`          | all-process  | yes           | `~/.config/starship.toml`| `%USERPROFILE%\.config\starship.toml`| —                                                      |
| `HOME`                     | all-process  | no            | —                      | `%USERPROFILE%`                        | Windows only                                            |
| `NIX_PATH`                 | all-process  | no            | —                      | `nixpkgs=flake:nixpkgs`                | Windows only                                            |
| `PATH`                     | all-process  | no            | sessionPath (shell) + launchctl (GUI domain) + environment.variables (NixOS) | Machine-scope REG_EXPAND_SZ via Sync-UserPath.ps1 | macOS: GUI domain via launchctl activation; shell via home.sessionPath. NixOS: all-process via environment.variables (GUI gap closed). Windows: Machine-scope REG_EXPAND_SZ with %USERPROFILE% literal entries (resolved per-user by CreateEnvironmentBlock). Sync-UserPath.ps1 replaces old DSC pathEnvVar (which was a literal set, not a prepend). |

## Adding a new variable

1. **Nix-side catalog**: add an entry in `src/modules/lib/env-vars.nix` `catalog` attrset.
   - Set `values = { default = ...; macOS = ...; NixOS = ...; Windows = ...; }`, `why`.
   - Use `values.default` for the primary value, per-OS keys for OS-specific overrides.
   - If the value depends on the logged-in user, set `userSpecific = true`.
   - If the var should be excluded from launchd, set `excludeFromLaunchctl = true`.
2. **Windows DSC**: if the var applies to Windows:
   - If `userSpecific = true`, add a DSC `Environment` resource in `src/hosts/Windows/user/env.dsc.yml` (User scope).
   - Otherwise, add the resource in `src/hosts/Windows/system/env.dsc.yml` (Machine scope).
3. **Tests**: ensure the parity test covers the new var:
   - `tests/integration/env-parity-tests.nix` generates a JSON manifest from the catalog.
   - `tests/hosts/Windows/EnvVarParity.Tests.ps1` reads the manifest and checks the DSC entries.
4. **Update this table** with the new row.
