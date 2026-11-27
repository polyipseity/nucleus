---
description: "Use when pinning a package from nixpkgs-next without bumping the main nixpkgs pin."
name: "Temporary nixpkgs Overrides"
applyTo: "src/flake.nix, src/modules/packages/nixpkgs-overrides.nix"
---

# Temporary nixpkgs overrides

`src/modules/packages/nixpkgs-overrides.nix` is the sole source for packages imported from pinned `nixpkgs-next` while the main `nixpkgs` pin stays older. The mechanism remains even when the file has no entries.

## Add an entry

Only when a required version exists in `nixpkgs-next` and the main pin cannot bump in the same change. Scope each entry to one package attribute and apply it through the shared overlay wired in `src/flake.nix`. No overrides elsewhere.

## Required markers

Every overlay entry carries adjacent comment lines with all three markers:

- `# TEMPORARY:` why the override exists now.
- `# REMOVE WHEN:` the concrete condition that makes it obsolete.
- `# WHY:` why the package must come from `nixpkgs-next`.

## Removal

Remove an entry in the commit that bumps `nixpkgs` past its `REMOVE WHEN` condition. Never delete the file when empty, and never remove `nixpkgs-next` wiring or this instruction while the mechanism exists. Keep the file header so the mechanism, discovery path, and removal rule remain visible in Nix source alone.
