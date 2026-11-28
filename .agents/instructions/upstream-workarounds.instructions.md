---
description: "Use when reviewing, adding, or removing workarounds for upstream limitations. Covers the categorized registry (temporary vs permanent), re-check cadence, and grep markers."
name: "Upstream Workarounds Registry"
applyTo: "src/**/*.nix, src/**/*.ps1, src/**/*.sh, src/vms/**, .agents/instructions/**"
alwaysApply: false
---

# Upstream workarounds registry

A workaround compensates for an upstream limitation. Category A is temporary (upstream PR or issue exists): re-check quarterly and remove when fixed. Category B is permanent or structural: listed only, no re-check. The current registry is W01 through W24 in `src/users/default/agents/skills/nucleus-platform-reference/references/upstream-workarounds.md`.

Check markers: `# WHY:` lines containing `PR #`, `issue #`, `nixpkgs`, `upstream`, `nix-darwin`, or `UTM #`; `overrideAttrs` on named packages; `patches = [ ./... ]`; `substituteInPlace`; `permittedInsecurePackages`. Quarterly cadence aligns with T3 review in `allow-and-deny-lists.instructions.md`.

Not workarounds: minimumReleaseAge, clawhub downgrade, brew tap pins, flake input follows, and the nonexistent redis MACOS_SDK case. Details and explanations for W18 and W11: the same reference file.
