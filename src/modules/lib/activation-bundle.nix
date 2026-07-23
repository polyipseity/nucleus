# src/modules/lib/activation-bundle.nix
# Thin wrapper around script-tree.nix for activation block use.
# All paths are repo-root-relative (e.g. "${activationBundle}/src/scripts/configs/foo.sh").
{ pkgs }:

pkgs.callPackage ./script-tree.nix { }
