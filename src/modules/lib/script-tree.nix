# src/modules/lib/script-tree.nix — Single derivation bundling all scripts
# from src/scripts/ with the exact repo directory structure at $out/ root.
# The $out/ layout mirrors the repo root, making all paths repo-root-relative.
# Provides shellchecked scripts for both activation blocks and
# writeNucleusShellApplication wrappers.
#
# Scripts source library dependencies via SCRIPT_DIR-relative paths
# (e.g. $SCRIPT_DIR/../lib/symlink-hardening-lib.sh), which work identically
# regardless of whether the tree is consumed directly or nested under
# another derivation's $out/src/scripts/.
{ pkgs }:

pkgs.runCommand "nucleus-script-tree"
  {
    nativeBuildInputs = [ pkgs.shellcheck ];
    preferLocalBuild = true;
  }
  ''
    mkdir -p "$out/src"
    cp -r "${../../../src/scripts}" "$out/src/scripts"
    chmod -R +x "$out"
    # Shellcheck all scripts so consumers don't need to re-check.
    find "$out" -name '*.sh' -exec shellcheck --source-path="$out" -x {} +
  ''
