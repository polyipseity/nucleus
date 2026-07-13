# Environment variable registry

This document is the cross-reference between the Nix-side centralized registry and the Windows parallel registry.

## Registry locations

| OS      | Location                                                        | Format      |
| ------- | --------------------------------------------------------------- | ----------- |
| macOS   | `src/modules/lib/env-vars.nix` (catalog)                        | Nix attrs   |
| NixOS   | `src/modules/lib/env-vars.nix` (catalog)                        | Nix attrs   |
| Windows | `src/hosts/Windows/user/env.dsc.yml`                            | WinGet DSC  |
| Windows | `src/hosts/Windows/modules/user/Sync-ShellProfile.ps1` (CC/CXX/LD) | PowerShell |

**Nix-side registry** (`src/modules/lib/env-vars.nix`):

- Declares every var in a single `catalog` attrset with `value`, `scope`, `hosts`, `why`, and optional `override` (per-OS).
- Pure helper functions (`toHomeSessionVariables`, `toNixOSEnvironment`, `toLaunchctlScript`, `toNixOSServiceEnv`) transform the catalog into platform-specific formats.
- Consumed by: `home.nix`, `shell.nix`, `macos.nix` (LaunchAgent), `hosts/NixOS/base.nix`, `hosts/NixOS/ai.nix`.
- The `env/default.nix` Home Manager module exposes `config._nucleus.envVars` for introspection.

**Windows parallel registry** (`src/hosts/Windows/user/env.dsc.yml`):

- Manually maintained as WinGet DSC resources.
- Must mirror the Nix catalog's Windows-relevant vars.  Parity is enforced by automated tests (see below).

## Managed variables

| Variable                   | Scope        | Nix                    | Windows (DSC)                          | Notes                                                  |
| -------------------------- | ------------ | ---------------------- | -------------------------------------- | ------------------------------------------------------ |
| `EDITOR`                   | all-process  | null (set by neovim)   | `nvim`                                 | macOS LaunchAgent hardcodes `nvim`                     |
| `VISUAL`                   | all-process  | null (set by neovim)   | `nvim`                                 | macOS LaunchAgent hardcodes `nvim`                     |
| `CC`                       | shell-only   | LLVM clang store path  | `Sync-ShellProfile.ps1`                | macOS: shell-only; NixOS/Windows: all-process          |
| `CXX`                      | shell-only   | LLVM clang++ store path| `Sync-ShellProfile.ps1`                | same as CC                                              |
| `LD`                       | shell-only   | LLVM lld store path    | `Sync-ShellProfile.ps1`                | same as CC                                              |
| `DEVELOPER_DIR`            | all-process  | Nix apple-sdk path     | —                                      | macOS only                                              |
| `SDKROOT`                  | all-process  | macOS SDK path         | —                                      | macOS only                                              |
| `LIBRARY_PATH`             | all-process  | libiconv store path    | —                                      | macOS only                                              |
| `NIX_SSL_CERT_FILE`        | all-process  | cacert bundle path     | —                                      | macOS only                                              |
| `OPENCODE_DISABLE_AUTOUPDATE`| all-process| `true`                 | `true`                                 | —                                                      |
| `OLLAMA_HOST`              | all-process  | `127.0.0.1:4000`       | `127.0.0.1:4000`                       | —                                                      |
| `OLLAMA_FLASH_ATTENTION`   | all-process  | `1`                    | `1`                                    | NixOS + Windows only                                   |
| `OLLAMA_CONTEXT_LENGTH`    | all-process  | `32768`                | `32768`                                | NixOS + Windows only                                   |
| `OLLAMA_KV_CACHE_TYPE`     | all-process  | `q4_0`                 | `q4_0`                                 | NixOS + Windows only                                   |
| `PASSWORD_STORE_DIR`       | all-process  | per-user path          | `%USERPROFILE%\dev\...`                | —                                                      |
| `GOPASS_CONFIG_COUNT`      | all-process  | `1`                    | `1`                                    | —                                                      |
| `GOPASS_CONFIG_KEY_1`      | all-process  | `path`                 | `path`                                 | —                                                      |
| `GOPASS_CONFIG_VALUE_1`    | all-process  | per-user path          | `%USERPROFILE%\dev\...`                | —                                                      |
| `NUCLEUS_DEFAULT_DEV_BIN`  | all-process  | defaultDevTools path   | `%USERPROFILE%\scoop\shims`            | Platform-appropriate fallback toolchain path           |
| `NUCLEUS_DEFAULT_DEV_ENV`  | all-process  | `1`                    | `1`                                    | —                                                      |
| `NUCLEUS_HOST`             | all-process  | `MacBook` / `NixOS`    | `Windows` (`apply.ps1`)                | Per-OS identity, Windows set in `apply.ps1`            |
| `NUCLEUS_REPO_ROOT`        | all-process  | eval-time env var      | —                                      | macOS only (apply.sh export)                           |
| `STARSHIP_CACHE`           | all-process  | `~/.cache/starship`    | `%USERPROFILE%\.cache\starship`        | —                                                      |
| `STARSHIP_CONFIG`          | all-process  | `~/.config/starship.toml`| `%USERPROFILE%\.config\starship.toml`| —                                                      |
| `HOME`                     | all-process  | —                      | `%USERPROFILE%`                        | Windows only                                            |
| `NIX_PATH`                 | all-process  | —                      | `nixpkgs=flake:nixpkgs`                | Windows only                                            |

## Adding a new variable

1. **Nix-side catalog**: add an entry in `src/modules/lib/env-nix.nix` `catalog` attrset.
   - Set `value`, `scope`, `hosts`, `why`.
   - If the value differs per OS, add `override = { macOS = ...; NixOS = ...; }`.
   - If the var is set externally (e.g. by `programs.neovim.defaultEditor`), set `value = null`.
2. **Windows DSC**: if the var applies to Windows, add a DSC `Environment` resource in `src/hosts/Windows/user/env.dsc.yml`.
3. **Windows PowerShell profile**: if the var is CC/CXX/LD or another shell-only var, add it to `src/hosts/Windows/modules/user/Sync-ShellProfile.ps1`.
4. **Tests**: ensure the parity test covers the new var:
   - `tests/integration/env-parity-tests.nix` generates a JSON manifest from the catalog.
   - `tests/hosts/Windows/EnvVarParity.Tests.ps1` reads the manifest and checks the DSC entries.
5. **Update this table** with the new row.
