---
description: "Reference: host vs platform naming layers, decision tree, canonical helpers, SSOT files, and cross-surface identifier mapping. Read on demand when adding services, env vars, config paths, or activation steps."
name: "Host/Platform Naming Reference"
---

# Host/platform naming reference

## Three layers

| Layer | Values | Role |
| ----- | ------ | ---- |
| **Host** | `MacBook`, `NixOS`, `Windows` | Primary lookup key: services, env-catalog, config paths, flake attrs, `NUCLEUS_HOST`, user registry maps |
| **Platform** | `macOS`, `NixOS`, `Windows` | OS-family entity; owns `flags` (`darwin`, `posix`, `linux`, `win32`); VM guest `type` |
| **Implementation** | `uname`, `stdenv.isDarwin`, nixpkgs `system` | Boundary only — map immediately via `host-platform-registry.json` |

## Rules

- Host JSON entries reference platform by name only (`"platform": "macOS"`). **Never put flags on host objects.**
- Flags live in `host-platform-registry.json` → `platforms.<PlatformKey>.flags` only.
- Lookup host first. When flags are needed: `platformForHost(host)` → `flagsForPlatform(platform)`.
- `services.json` uses `hosts.MacBook|NixOS|Windows`, not `platforms.macos|nixos|windows`.
- Flake configuration attrs: `darwinConfigurations.MacBook`, `nixosConfigurations.NixOS`.
- Env-catalog `values` keys and `resolveValue` use host names (`MacBook`, not `macOS`).
- Config paths under `src/modules/configs/` use host directory names (`MacBook/`, `NixOS/`, `Windows/`).
- Script prefixes (`macos-`, `nixos-`) and nixpkgs `meta.platforms` are implementation boundaries — do not rename to host keys.

## Decision tree

1. Is the data keyed by physical machine identity? → **Host key** (`MacBook`, `NixOS`, `Windows`).
2. Is the data about OS-family semantics or implementation flags? → **Platform key** (`macOS`, `NixOS`, `Windows`).
3. Is the data from nixpkgs, kernel, or third-party API? → Keep upstream naming; map at the boundary via registry helpers.

## Canonical helpers

| Surface | Host resolution | Platform / flags |
| ------- | --------------- | ---------------- |
| Nix | `host-platform.nix` → `platformForHost`, `flagsForHost` | `flagsForPlatform` |
| POSIX shell | `resolve_nucleus_host` | `nucleus_platform_for_host`, `nucleus_flag_for_host` |
| PowerShell | `Get-NucleusHostKey` (`$env:NUCLEUS_HOST` or `Windows`) | `Get-NucleusPlatformForHost`, `Test-NucleusPlatformFlag` in `Get-NucleusHostPlatform.ps1` |

## SSOT files

- `src/modules/host-platform-registry.json` — host → platform refs; platform → flags
- `src/modules/services.json` — per-service `hosts.*` with required `platform` field
- `src/modules/lib/env-catalog.nix` — `values.MacBook|NixOS|Windows`

## Audit

Host vs platform vs implementation naming is enforced by service-registry validation (check step 8).

## Cross-surface identifier mapping

The same activation or apply step is named across five identifier surfaces. Each surface keeps its platform-native format; this table is the canonical cross-boundary reference.

| Surface | Convention | Example |
| ------- | ---------- | ------- |
| Nix/POSIX activation entries (`home.activation.*`, `system.activationScripts.*`, `nucleus.terminalActivations.*`) | kebab-case, verb-first (see `activation-scripts.instructions.md`) | `write-terminal-activations` |
| DSC file IDs | `<scope>/<kebab-name>.dsc.yml` | `user/shell.dsc.yml` |
| PowerShell functions/modules | PascalCase with approved verbs (`Sync-*`, `Deploy-*`, `Invoke-*`, `Get-*`, `Set-*`) | `Sync-TerminalActivation` |
| POSIX apply step functions (`src/scripts/apply.sh`) | snake_case `run_*` | `run_terminal_activations` |
| Stage labels (`src/scripts/apply.sh`, `src/hosts/Windows/apply.ps1`) | `<label>:` kebab-case | `terminal-activations:` |

### Worked cross-boundary pair

`write-terminal-activations` (activation entry) ↔ `Sync-TerminalActivation` (PowerShell) ↔ `terminal-activations:` (stage label) ↔ `run_terminal_activations` (apply function) name the same step across all surfaces. The singular/plural asymmetry is deliberate: the PowerShell verb is singular `Sync-TerminalActivation` (renamed from `Sync-TerminalActivations` in commit "fix(pwsh): rename Sync-TerminalActivations to Sync-TerminalActivation"), while the activation entry and stage label use plural. Do NOT "fix" this — the mapping documents the asymmetry as-is.

### Kept-as-is decisions

- `Disable-SteamAutoStartup` keeps the approved `Disable` verb.
- `config-utils.nix` generated names (`unprotectSymlink_${name}` etc.) are exempt from the kebab-case rule; the Windows side mirrors this exemption with `ConfigHelpers.ps1` `Deploy-*` generated names.

### Known stage-label gaps

Documented but NOT fixed — intentional parity gaps for future work:

- POSIX `apply.sh` lacks the `svc:`, `vm-setup:`, `vm-sync:` labels that Windows `apply.ps1` emits.
- Windows `apply.ps1` lacks the `health-check:` and `caddy-local-ca-trust:` labels that POSIX emits.
