# src/modules/lib/script-tree.nix — Single derivation bundling all scripts
# from src/scripts/ with the exact repo directory structure at $out/ root.
# The $out/ layout mirrors the repo root, making all paths repo-root-relative.
# Provides scripts for both activation blocks and writeNucleusShellApplication
# wrappers. Shellcheck runs in nucleus-check-sh / CI, not at derivation build time.
#
# Scripts source library dependencies via SCRIPT_DIR-relative paths
# (e.g. $SCRIPT_DIR/../lib/symlink-hardening.sh), which work identically
# regardless of whether the tree is consumed directly or nested under
# another derivation's $out/src/scripts/.
{ pkgs }:

pkgs.runCommand "nucleus-script-tree"
  {
    preferLocalBuild = true;
  }
  ''
    mkdir -p "$out/src"
    cp -r "${../../../src/scripts}" "$out/src/scripts"
    chmod -R +x "$out"
  ''
