---
description: "Use when reviewing, adding, or removing workarounds for upstream limitations. Covers the categorized registry (temporary vs permanent), re-check cadence, and grep markers."
name: "Upstream Workarounds Registry"
applyTo: "src/**/*.nix, src/**/*.ps1, src/**/*.sh, src/vms/**, .agents/instructions/**"
alwaysApply: false
---

# Upstream workarounds registry

A workaround compensates for an upstream limitation. Two categories:

- **A. Temporary** — upstream fix expected (PR/issue exists). Re-check quarterly; remove when the upstream fix lands.
- **B. Permanent** — will not be fixed by upstream updates or is structural. Listed only, no re-check.

## Registry

### A. Temporary

| ID | Location | Workaround | Upstream link | Re-check trigger |
|----|----------|------------|---------------|------------------|
| W01 | (removed) | frei0r: gate gavl — REMOVED (nixpkgs already gates gavl; PR #549406 merged) | nixpkgs PR #549747 (open) | removed 2026-10-31 |
| W02 | src/flake.nix:485-494 | sandbox-runtime: substituteInPlace Seatbelt profile to allow System V semaphores | anthropic/sandbox-runtime; codex #28921 | Profile carries ipc-sysv-sem |
| W03 | src/flake.nix:36-59 | brew-src pinned to 7.0.11 + cirruslabs/cli tap | nix-homebrew#192 | brew-src bump |
| W04 | src/platforms/macOS/modules/default.nix:353 | launchctl config unreliable | nix-darwin#1080 | issue resolves |
| W05 | src/hosts/MacBook/camilladsp.nix:66, jellyfin.nix:44, https-proxy.nix:72, service-watchdog.nix:42 | TCC/launchd ownership | nix-darwin#1219 | issue resolves |
| W06 | src/hosts/MacBook/linux-builder.nix:105 | /etc/nix/builder_ed25519 ownership | nix-darwin builder | upstream changes ownership |
| W07 | src/platforms/Windows/modules/user/Sync-HermesConfig.ps1:190 | HERMES_HOME env var | hermes-agent installer | installer sets HERMES_HOME |
| W08 | src/scripts/editors/neovim-init.lua:6,10,33 | enable_shift_number_symbols_workaround | neovim/terminal | regression fixed |
| W09 | src/modules/vms/VMs.json (Android) | sound=none | UTM #2221/#2364/#4781 | UTM fixes deadlock |
| W10 | src/hosts/MacBook/activation.nix (Spotlight) | six-step Spotlight disable | macOS SIP/launchd | SIP allows declarative disable |
| W11 | src/flake.nix:467 | gnupg pinned to 2.5.19, patches=[], postPatch="" | nixpkgs gnupg patch stack (2.4-only) | patch stack targets 2.5 |
| W12 | src/flake.nix:145-180 | davs2/kvazaar/etc doCheck=false on Darwin | nixpkgs test incompatibility | nixpkgs fixes Darwin tests |
| W13 | src/flake.nix:154 | mat2 dontUsePytestCheck | nixpkgs pytest-check-hook | hook registers checkPhase |
| W14 | src/flake.nix:290-310 | rimsort custom derivation | nixpkgs | nixpkgs adds rimsort |
| W15 | src/flake.nix:340-360 | steamcmd custom derivation | Valve CDN / nixpkgs | nixpkgs adds steamcmd Darwin |
| W16 | src/flake.nix:378-390 | camilladsp custom derivation | WinGet/Scoop | upstream adds to WinGet/Scoop |
| W17 | src/flake.nix:139-140 | dotnet-runtime-6.0.36 permittedInsecurePackages | .NET EOL | EIDE uses newer .NET |
| W18 | src/modules/ext-discord-music-rpc.nix:85 | substituteInPlace pyproject.toml (drops git dep on pypresence) | upstream packaging | upstream drops git dep |
| W19 | src/flake.nix:443-452 | litellm stripExclude *.ico/*.cur on Darwin | nixpkgs PR #539458 | PR merges |
| W20 | src/modules/configs/ (psgallery) | psgallery pin+hash (no upstream age feature) | PSGallery API | PSGallery adds age feature |
| W21 | src/modules/lib/vagrant-plugins.nix | vagrant-utm-gemspec.patch | vagrant-utm | upstream fixes gemspec |
| W22 | src/vms/NixOS/disk-image/make-btrfs-disk-image.nix | make-disk-image-btrfs.patch | nixos-generators | upstream adds btrfs |

### B. Permanent

| ID | Location | Workaround | Reason |
|----|----------|------------|--------|
| W23 | src/vms (android) | fake-wifi guest scripts | guest has no Nix store; structural |
| W24 | src/flake.nix:489 | SIP launchd daemon /bin/sh wrapper | SIP policy; permanent |

## How to check

Grep markers indicating a workaround (used by the check step):

- `# WHY:` lines containing `PR #`, `issue #`, `nixpkgs`, `upstream`, `nix-darwin`, `UTM #`.
- `overrideAttrs` on named packages (frei0r, sandbox-runtime, litellm, gnupg25_pinned).
- `patches = [ ./... ]` and `substituteInPlace`.
- `permittedInsecurePackages`.

Quarterly cadence, aligned with T3 review in `allow-and-deny-lists.instructions.md`.

## Excluded (not workarounds)

- minimumReleaseAge / exclude-newer: supply-chain policy.
- clawhub version downgrade: supply-chain age compliance.
- brew tap pins (openai-tools, cirruslabs, smudge): configuration.
- flake input follows = nixpkgs: dedup.
- redis MACOS_SDK: no such workaround in repo.

## Explanations

- ext-discord-music-rpc (W18): build-time substituteInPlace removes `pypresence @ git+...` from pyproject.toml because pip would clone it at build time; propagatedBuildInputs already provides pypresence. Temporary.
- gnupg (W11): pinned to 2.5.19 with patches=[] and postPatch="" because the nixpkgs patch stack targets the 2.4 branch only. Temporary.
