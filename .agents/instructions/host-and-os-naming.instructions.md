---
description: "Use when naming hosts, platforms, or OS implementation boundaries in nucleus JSON, Nix, shell, or PowerShell. Defines the three-layer host/platform/implementation model and host-first lookup rules."
name: "Host and OS naming"
applyTo: "src/modules/**/*.json, src/modules/**/*.nix, scripts/**/*.{sh,ps1}, src/scripts/**/*.{sh,ps1}"
---

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
| PowerShell | `Get-NucleusHostKey` (Windows = `Windows`) | read `host-platform-registry.json` |

## SSOT files

- `src/modules/host-platform-registry.json` — host → platform refs; platform → flags
- `src/modules/services.json` — per-service `hosts.*` with required `platform` field
- `src/modules/lib/env-catalog.nix` — `values.MacBook|NixOS|Windows`
