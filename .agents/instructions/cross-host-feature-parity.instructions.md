---
description: "Use when adding or changing capabilities across hosts, GC timing, or provisioned symlinks."
name: "Cross-Host Feature Parity"
applyTo: "src/modules/**/*.json, src/modules/**/*.nix, src/hosts/**/*.nix, src/hosts/Windows/**/*.yml, scripts/**/*.{sh,ps1}, src/scripts/**/*.{sh,ps1}, scripts/gc.*"
---

# Cross-host feature parity

# Upstream workarounds registry: .agents/instructions/upstream-workarounds.instructions.md

Same capability on every host. Shared POSIX behavior lives in `src/modules/` or `src/scripts/`; Windows uses PowerShell under `src/platforms/Windows/modules/` with orchestration-only `apply.ps1`, never `.sh` paths. A difference needs `# WHY:`. Evaluate MacBook, NixOS, and Windows before writing and implement all applicable hosts together; state implemented, already in parity, or not practical yet. Sweep packages, tooling, security, desktop, remote access, secrets, editor, git, power, network, and automation.

Merge macOS and NixOS twins with `builtins.replaceStrings` or `case "$(uname)"`. Windows imperative parity needs config, cleanup, idempotence, managed-state-only changes, and an enable/disable toggle wired in `apply.ps1`; failed starts warn without aborting.

All kills, refreshes, and restarts go through `refresh_*` (`macos-launch-services.sh`) or `Set-NucleusService.ps1`; restart each daemon once per activation. Services default to persistent daemons; oneshot classes live in `src/users/default/agents/skills/nucleus-service-reference/references/service-firing-policy.md`. A cross-host tool lands in `core.nix` and `system-packages.dsc.yml` together; Windows source builds pin commit hashes. GC precedence: CLI flag, per-tool env, master flag or env, Nix default, then `7d`/`7`.

Every provisioned symlink is writable and delete-protected where possible; NixOS verifies by detection. Read-only is required for Nix store targets; deviations need `# WHY:`. Details and the imperative-code list: `src/users/default/agents/skills/nucleus-platform-reference/references/cross-host-feature-parity.md`.
