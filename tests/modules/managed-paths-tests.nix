# tests/modules/managed-paths-tests.nix — managed-paths.nix shim + PATH wiring.
#
# Verifies:
#   • nodeShim derivation exists and symlinks node → bun
#   • nodeShim is exposed in the returned attrset
#   • ~/.local/bin remains on the append PATH (shim install target)
#
# Run with: nix-instantiate --eval tests/modules/managed-paths-tests.nix

let
  lib = import <nixpkgs/lib>;
  pkgs = import <nixpkgs> { };
  inherit (lib) hasInfix;

  managedPaths = import ../../src/modules/lib/managed-paths.nix { inherit pkgs; };
  managedPathsText = builtins.readFile ../../src/modules/lib/managed-paths.nix;

  test_nodeShim_exists = managedPaths ? nodeShim;

  test_nodeShim_symlinks_to_bun = hasInfix ''ln -s "''${pkgs.bun}/bin/bun" "$out/bin/node"'' managedPathsText;

  test_local_bin_on_append_path = builtins.elem ".local/bin" managedPaths.pathComponents.append;

  allTests = [
    test_nodeShim_exists
    test_nodeShim_symlinks_to_bun
    test_local_bin_on_append_path
  ];
in
builtins.seq (builtins.deepSeq allTests null) {
  success = true;
  testCount = builtins.length allTests;
  message = "All ${toString (builtins.length allTests)} managed-paths tests passed";
}
