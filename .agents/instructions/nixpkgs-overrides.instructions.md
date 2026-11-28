---
description: "Use when pinning a package from nixpkgs-next without bumping the main nixpkgs pin."
name: "Temporary nixpkgs Overrides"
applyTo: "src/flake.nix, src/modules/packages/nixpkgs-overrides.nix"
---

# Temporary nixpkgs overrides

`src/modules/packages/nixpkgs-overrides.nix` is the only source for packages from pinned `nixpkgs-next` while the main pin stays older; the mechanism remains when the file is empty. Add an entry only when a required version exists in `nixpkgs-next` and the main pin cannot bump in the same change, scoped to one package attribute through the shared overlay in `src/flake.nix`.

Every entry carries adjacent `# TEMPORARY:` (why now), `# REMOVE WHEN:` (concrete condition), and `# WHY:` (why `nixpkgs-next`) markers. Remove entries in the pin-bump commit; never delete the file, the wiring, or this instruction while the mechanism exists. Keep the file header intact.

Details: `src/users/default/agents/skills/nucleus-platform-reference/references/nixpkgs-overrides.md`.
