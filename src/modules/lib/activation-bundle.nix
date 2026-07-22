# src/modules/lib/activation-bundle.nix
# Single derivation that bundles all scripts from src/scripts/ into a
# self-contained store path. Scripts source library dependencies via
# SCRIPT_DIR-relative paths, eliminating builtins.readFile concatenation
# in activation blocks and cross-file dependency tracking at Nix eval time.
#
# Every .sh file under $out/ is an executable that:
#   1. Sets SCRIPT_DIR from $0
#   2. Sources needed libs via "$SCRIPT_DIR/../lib/<name>.sh"
#   3. Executes the activation logic
#
# All activation blocks invoke these scripts as subprocesses.
# No inline ${builtins.readFile} in activation bodies.
{ pkgs }:

pkgs.runCommand "nucleus-activation-bundle" { preferLocalBuild = true; } ''
  cp -r "${../../../src/scripts}/." "$out/"
  chmod -R +x "$out"
''
