---
description: "Use when editing the lockfile, its enforcement lib, or the update lockfile action."
name: "Lockfile Enforcement"
applyTo: "src/lockfiles/lockfile.json, src/lockfiles/lockfile.schema.json, src/scripts/checks/check-steps/05-lockfile-validation.*, src/scripts/checks/lockfile-enforcement-lib.*, src/platforms/Windows/modules/user/Sync-SuperpowersPlugin.ps1, src/platforms/Windows/modules/user/Sync-OpenCodeConfig.ps1"
---

# Lockfile enforcement

`lockfile.json` pins versions; its schema is authoritative and every section is required, possibly `{}`. Homebrew has no cask pins; taps follow `flake.lock`, and only `suggestions.homebrew.masApps` lives here. Update with `scripts/update.sh`/`.ps1`; Nix pins come from `nix flake lock` in `src/`. Object-shaped uv, bun, and pi pins are skipped; psgallery recomputes hashes for object entries.

Pinned root hard-fails on drift; `suggestions` is warn-only. Anything that can only warn, plus VCS/rev pins and cross-host data, belongs in `suggestions`. `suggestions.vscode` is the sole duplication exception because Windows cannot evaluate Nix. `psgallery` uses version plus nupkg SHA256 and cannot verify the hash against an installed module; whisper uses `{revision, hash, url}` with revision embedded in the URL and rehashes the deployed copy under `<USER root>/models` (POSIX `-v` in `od -An -v -tx1` is load-bearing).

Probes live only in `lockfile-enforcement-lib.*` for the update action; step 05 checks structure. Probes scope to `desired.json` and resolve `flake:` pins against `flake.lock`. `cursor.superpowers` pins source plus rev on both hosts. `--verify` diffs; `--verify-installed` compares installed versions, never writes, and warns for suggestions.

Details: `.agents/skills/nucleus-policy-reference/references/lockfile-enforcement.md`.
