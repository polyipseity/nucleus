---
description: "Use when pinning a package from nixpkgs-next without bumping the main nixpkgs pin. Covers the temporary nixpkgs override mechanism, entry markers, and removal rules."
name: "Temporary nixpkgs Overrides"
applyTo: "src/flake.nix, src/modules/packages/nixpkgs-overrides.nix"
---

# Temporary nixpkgs overrides

`src/modules/packages/nixpkgs-overrides.nix` is the single source of truth for packages imported from the pinned `nixpkgs-next` flake input because the main `nixpkgs` pin is older and bumping it is not desired yet. The mechanism is permanent and must remain even when the file has no package entries.

## When to add an entry

- Add an entry only when a package version available in `nixpkgs-next` is required and the main `nixpkgs` pin cannot be bumped in the same change.
- Keep each entry scoped to one package attribute and apply it through the shared overlay wired in `src/flake.nix`.
- Do not duplicate package overrides elsewhere; this file is the only override location.

## Required markers

Every package entry in the overlay body must carry all three markers on comment lines adjacent to that entry:

- `# TEMPORARY:` why this override exists now.
- `# REMOVE WHEN:` the concrete condition that makes the override obsolete (for example, the pinned `nixpkgs` provides the required version).
- `# WHY:` why this package must come from `nixpkgs-next`.

## Removal and lifecycle

- Remove an entry in the same commit that bumps the `nixpkgs` pin far enough to satisfy its `REMOVE WHEN` condition.
- Never delete `src/modules/packages/nixpkgs-overrides.nix` when it becomes empty, and never remove the `nixpkgs-next` wiring or this instruction while the mechanism exists.
- Keep the file header intact so the mechanism, discovery path, and removal rule remain obvious from the Nix source alone.
