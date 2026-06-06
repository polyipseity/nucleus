---
description: "Use when reviewing or modifying GC/retention timings in Nix modules, GC scripts, or host DSC configs. Single source of truth for all expiry intervals."
name: "GC and Retention Policy"
applyTo: "src/**/*.nix, scripts/gc.*, src/hosts/Windows/**/*.yml"
---

# GC and Retention Policy

Timing values are specified directly at their point of use — this file does
not maintain a duplicate table. To find or change a retention interval, look
in the relevant source file:

| Category                  | Source files                                                                 |
| ------------------------- | ---------------------------------------------------------------------------- |
| Nix store GC, HM expiry   | `src/modules/posix-base.nix`, `scripts/gc.sh`                                |
| macOS timers & defaults   | `src/modules/macos.nix`, `src/hosts/MacBook/defaults.nix`                    |
| Linux timers & timeouts   | `src/modules/linux.nix`, `src/modules/posix-security.nix`                    |
| Windows schedules & timeouts | `src/hosts/Windows/system.dsc.yml`, `src/hosts/Windows/user.dsc.yml`, `src/hosts/Windows/modules/system/*.ps1` |
| Cloud drive caches        | `src/modules/cloud-drives.nix`                                               |
| AI/LLM timeouts           | `scripts/ai-sync.sh`, `scripts/gc.sh`                                        |
| Declarative-diff GC items | `scripts/gc.sh`, `scripts/gc.ps1`                                            |
| App-level timeouts        | `src/modules/editors.nix`, `src/modules/configs/picard/Picard.ini`           |

## Authoring rule

- When changing a timing value, update the actual configuration in the source
  file listed above. No separate timing manifest needs updating.
