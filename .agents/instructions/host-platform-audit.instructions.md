---
description: "Use when auditing host vs platform vs implementation naming across nucleus. Provides the full usage matrix, per-surface inventory, grep patterns, and PASS/WARN/VIOLATION classification for check step 27."
name: "Host platform audit"
applyTo: "src/modules/**/*.{json,nix}, scripts/**/*.{sh,ps1}, src/scripts/**/*.{sh,ps1}, .agents/instructions/**/*.md"
---

## Preference rule

When data answers **which machine runs this?**, use **host** (`MacBook`, `NixOS`, `Windows`). Platform is for OS-family refs and flags. Implementation (`stdenv`, `uname`, nixpkgs) is boundary-only — map immediately via registry helpers. See [`host-and-os-naming.instructions.md`](host-and-os-naming.instructions.md).

## Category matrix

| Cat | Layer | When | Keys | SSOT / helpers |
| --- | ----- | ---- | ---- | -------------- |
| **A** | Host | Machine identity, per-host config, services, env, flake, user maps | `MacBook`, `NixOS`, `Windows` | `NUCLEUS_HOST`, `resolve_nucleus_host`, `Get-NucleusHostKey`, `hostKeys` |
| **B** | Platform | OS-family on host entries, registry flags, VM guest `type`, guest artifact paths | `macOS`, `NixOS`, `Windows`, `Android` (VM) | `platformForHost`, `Get-NucleusPlatformForHost`, `host-platform-registry.json` → `platforms.*` |
| **C** | Implementation | nixpkgs eval, package filters, merged-script OS branches | `darwin`/`linux`/`posix`/`win32`, `stdenv`, `uname` | Map at boundary; never store as lookup keys |
| **D** | VM dual | Provisioning host vs guest OS | `hosts[]` + `NUCLEUS_HOST` (host) vs `type` (platform) | `VMs.json`, `vm-guest-identity.instructions.md` |
| **E** | Allowed exceptions | Script prefixes, module filenames, vendor paths | `macos-*`, `nixos-*`, `macos.nix`, `src/vms/macOS/` | AGENTS.md — do not rename to host keys |
| **F** | Violations | Legacy / wrong layer | `platforms` on services, `values.macOS`, lowercase host config paths | Zero tolerance |

## A — Host surfaces (audit inventory)

| Surface | Paths |
| ------- | ----- |
| Registry | `src/modules/host-platform-registry.json`, `src/modules/lib/host-platform.nix` |
| Services | `src/modules/services.json` → `hosts.*`, `$logging.*` |
| Env catalog | `src/modules/lib/env-catalog.nix` → `values.MacBook\|NixOS\|Windows`, `currentHost` |
| Flake | `src/flake.nix` → `darwinConfigurations.MacBook`, `nixosConfigurations.NixOS` |
| User registry | `src/users/**` host maps (`homeDirectory`, `localPath`, `enable`, `targets`) |
| Config paths | `src/modules/configs/` → `MacBook/`, `NixOS/`, `Windows/`, `*.{MacBook,NixOS,Windows}.*` |
| Host trees | `src/hosts/MacBook/`, `NixOS/`, `Windows/` |
| Runtime | `src/scripts/lib/lib.sh`, `Get-NucleusHostPlatform.ps1`, `scripts/svc.sh`, `scripts/vm.sh` |
| Lockfile (host pkgs) | `src/lockfiles/lockfile.json` → top-level `MacBook`, `NixOS`, `Windows` arrays |

## B — Platform surfaces (legitimate)

| Surface | Paths |
| ------- | ----- |
| Service platform refs | `services.json` → `hosts.*.platform` |
| Registry flags | `host-platform-registry.json` → `platforms.*.flags` |
| VM guest type | `VMs.json` → `type`; `src/vms/<type>/` |
| Lockfile guest pins | `lockfile.json` → `vms.windows` (guest ISO — not host) |

## C — Implementation (WARN only outside boundary allowlist)

Boundary allowlist: `lib.sh`, `apply.sh`, `host-platform.nix`, `vm.sh`, `src/scripts/lib/vm.sh`, `macos-launch-services.sh`, `core.nix`, `posix-*.nix`, `macos.nix`, `linux.nix`.

| Pattern | ~locations |
| ------- | ---------- |
| `stdenv.isDarwin` / `isLinux` | Nix modules, `flake.nix` |
| `uname -s` | Merged POSIX scripts, `apply.sh` |
| nixpkgs `meta.platforms` | `core.nix`, package tests |

## D — VM dual identity

- **Provisioning host:** `VMs.json` `hosts[]`, `NUCLEUS_HOST`, `vm.sh`/`vm.ps1` filters.
- **Guest OS:** `type`, `src/vms/<type>/`, runtime `~/virtual machines/src/<type>/`.
- **MacBook guest pattern:** `id: MacBook`, `type: macOS` (intentional split).

## E — Allowed exceptions (skip in violation count)

- `src/scripts/hosts/MacBook/macos-*.sh`, `src/modules/macos/`, `macos.nix`, `linux.nix`
- `src/vms/macOS/` (guest-type path casing)
- `cfg(target_os = "...")` in Cargo/Rust configs
- `org.nixos.*` labels in `services.json` (upstream identifiers)
- `lockfile.json` → `vms.windows` (guest section key)

## F — Violation grep patterns

Run from repo root. Exclude check-step error strings and this file when triaging.

### F1 — Legacy identifiers (must be zero hits)

```bash
rg -n 'currentOs|CURRENT_OS|macOSAllVars|usersMacOS|NUCLEUS_PLATFORM|\bPLATFORM=' \
  --glob '!src/scripts/checks/check-steps/26-host-os-naming.*' \
  --glob '!**/*.instructions.md'
```

### F2 — services.json legacy `platforms` key

```bash
jq -e 'to_entries[] | select(.key|startswith("$")|not) | select(.value|has("platforms"))' \
  src/modules/services.json
```

### F3 — env-catalog OS keys

```bash
rg -n 'values\.macOS' src/modules/lib/env-catalog.nix
```

### F4 — Flake lowercase attrs

```bash
rg -n 'darwinConfigurations\.(macbook|macBook|macos)|nixosConfigurations\.(nixos|nixOS|linux)' src/flake.nix
```

### F5 — User registry lowercase host keys

```bash
rg -n '"(macos|nixos|windows)"\s*:' src/users/
```

### F6 — Config path host casing (git index)

Host-keyed config paths must use `MacBook`, `NixOS`, `Windows` — not lowercase OS names:

```bash
git ls-files 'src/modules/configs/**' | rg '/(macos|nixos|windows)/|config-(macos|nixos|windows)\.'
```

### F7 — Code references to lowercase host config paths

```bash
rg -n 'configs/(macos|nixos|windows)/|config-(macos|nixos|windows)\.' src/ scripts/
```

### F8 — Test path casing vs on-disk artifact

`src/modules/configs/vms/nixos-domain.xml` is the canonical filename (guest artifact, lowercase `nixos` prefix). Tests must not reference `NixOS-domain.xml`.

### F9 — Host identity bypass (must be zero hits)

| Rule | Pattern | Rationale |
| ---- | ------- | --------- |
| **F9a** | `current_os=` or `currentOs` in `scripts/` | Legacy OS variable; use host helpers |
| **F9b** | `case "$(uname)"` assigning `MacBook`/`NixOS` outside allowlist | Host bypass |
| **F9c** | `IsOSPlatform` variables named `*Host` in `src/hosts/Windows/modules/` | OS check masquerading as host |

F9b allowlist (runtime kind / boundary only): `src/scripts/lib/lib.sh`, `src/scripts/apply.sh`, `src/scripts/lib/vm.sh`.

```bash
rg -n 'current_os=|currentOs' scripts/
rg -n '\w+Host\s*=.*IsOSPlatform' src/hosts/Windows/modules/
```

## Classification (check step 27)

| Result | Meaning |
| ------ | ------- |
| **PASS** | Category A/B inventory present; Category F pattern has zero hits |
| **WARN** | Category C hit outside boundary allowlist (manual triage) |
| **VIOLATION** | Any Category F hit; host config path casing mismatch (F6/F7/F8) |

## Automation

- **Runner:** `src/scripts/checks/host-platform-audit.sh <repo-root>`
- **CI step:** check step 27 (`host-platform-audit`)
- **Related:** check step 26 (subset of F2/F3 + registry cross-validation)
