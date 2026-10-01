---
description: "Reference: host vs platform naming layers, decision tree, canonical helpers, SSOT files, and cross-surface identifier mapping. Read on demand when adding services, env vars, config paths, or activation steps."
name: "Host/Platform Naming Reference"
---

# Host/platform naming reference

## Three layers

| Layer | Values | Role |
| ----- | ------ | ---- |
| **Host** | `MacBook`, `NixOS`, `Windows` | Primary lookup key: services, env catalog, config paths, flake attrs, `NUCLEUS_HOST`, user registry maps |
| **Platform** | `macOS`, `NixOS`, `Windows` | OS-family entity; owns `flags` (`darwin`, `posix`, `linux`, `win32`); VM guest `type` |
| **Implementation** | `uname`, `stdenv.isDarwin`, nixpkgs `system` | Boundary only, mapped immediately through the registry |

Data keyed by physical machine identity uses a host key. Data about OS-family semantics or flags uses a platform key. Anything coming from nixpkgs, the kernel, or a third-party API keeps its upstream name and gets mapped at the boundary.

Flags live only in `host-platform-registry.json` under `platforms.<PlatformKey>.flags`, never on host objects, and a host JSON entry references its platform by name (`"platform": "macOS"`). So `services.json` is keyed `hosts.MacBook|NixOS|Windows`, the env catalog `values` keys and `resolveValue` take host names, `src/modules/configs/` directories use host names, and the flake exposes `darwinConfigurations.MacBook` and `nixosConfigurations.NixOS`. Script prefixes (`macos-`, `nixos-`) and nixpkgs `meta.platforms` stay implementation-bound; do not rename them to host keys. Check step 8 enforces this on the service registry.

## Canonical helpers

| Surface | Host resolution | Platform / flags |
| ------- | --------------- | ---------------- |
| Nix (`host-platform.nix`) | `platformForHost` | `flagsForPlatform`, `flagsForHost` |
| POSIX shell | `resolve_nucleus_host` | `nucleus_platform_for_host`, `nucleus_flag_for_host` |
| PowerShell (`Get-NucleusHostPlatform.ps1`) | `Get-NucleusHostKey` (`$env:NUCLEUS_HOST` or `Windows`) | `Get-NucleusPlatformForHost`, `Test-NucleusPlatformFlag` |

SSOT: `src/modules/host-platform-registry.json` for host to platform and platform to flags, `src/modules/services.json` for per-service `hosts.*` with its required `platform` field, `src/modules/lib/env-secrets.nix` for `values.MacBook|NixOS|Windows`.

## Cross-surface identifier mapping

| Surface | Convention | Example |
| ------- | ---------- | ------- |
| Nix/POSIX activation entries (`home.activation.*`, `system.activationScripts.*`, `nucleus.terminalActivations.*`) | kebab-case, verb-first (`activation-scripts.instructions.md`) | `write-terminal-activations` |
| DSC file IDs | `<scope>/<kebab-name>.dsc.yml` | `user/shell.dsc.yml` |
| PowerShell functions/modules | PascalCase with approved verbs (`Sync-*`, `Deploy-*`, `Invoke-*`, `Get-*`, `Set-*`) | `Sync-TerminalActivation` |
| POSIX apply step functions (`src/scripts/apply.sh`) | snake_case `run_*` | `run_terminal_activations` |
| Stage labels (`src/scripts/apply.sh`, `src/hosts/Windows/apply.ps1`) | `<label>:` kebab-case | `terminal-activations:` |

One step, four spellings: `write-terminal-activations`, `Sync-TerminalActivation`, `terminal-activations:`, `run_terminal_activations`. The singular/plural asymmetry is deliberate (PowerShell singular, activation and stage plural), so do not "fix" it.

Kept as is: `Disable-SteamAutoStartup` keeps the approved `Disable` verb, and the `config-utils.nix` generated names (`unprotectSymlink_${name}` and friends) stay exempt from kebab-case, mirrored on Windows by the `Deploy-*` names in `ConfigHelpers.ps1`.

Known stage-label gaps, not fixed: POSIX `apply.sh` lacks the `svc:`, `vm-setup:`, and `vm-sync:` labels Windows emits, and Windows `apply.ps1` lacks the `health-check:` and `caddy-local-ca-trust:` labels POSIX emits.
