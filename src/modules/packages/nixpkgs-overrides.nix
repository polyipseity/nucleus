# TEMPORARY nixpkgs overrides
# Mechanism: this file defines a single overlay that imports packages from the
# pinned `nixpkgs-next` flake input so they are newer than the main `nixpkgs`
# pin. Discovery: see `.agents/instructions/nixpkgs-overrides.instructions.md`
# and the "Build and validation" bullet in `AGENTS.md`. Removal: delete an
# entry in the same commit that bumps the `nixpkgs` pin far enough to satisfy
# its removal condition. This file and the mechanism stay in the tree even when empty.

# TEMPORARY OVERRIDES
# Each entry pins one package from `nixpkgs-next` because the pinned nixpkgs is
# older and we do not want to bump the pin yet. Every entry needs its reason and
# its removal condition. An empty file is valid and must stay in the tree.
{ nixpkgsNext, ... }:
{
  overlay = _final: prev: {
    # TEMPORARY: pull claude-code from nixpkgs-next while the main pin is behind.
    # REMOVE WHEN: the pinned nixpkgs provides a usable claude-code for all hosts.
    # WHY: Claude Code must be provisioned on macOS, NixOS, and Windows in this slice.
    claude-code = nixpkgsNext.legacyPackages.${prev.stdenv.hostPlatform.system}.claude-code;
  };
}
