# src/modules/lib/script-tree.nix — Single derivation bundling scripts for activation
# and writeNucleusShellApplication wrappers. Bundles:
#   - src/scripts/ (cross-host POSIX)
#   - src/platforms/ (platform activation scripts)
#   - src/hosts/<Host>/scripts/ (host-only activation scripts; selective, not full hosts tree)
# The $out/ layout mirrors the repo root under $out/src/, making paths repo-root-relative.
# Shellcheck runs in nucleus-check sh / CI, not at derivation build time.
#
# WHY: every bundled directory is interpolated on its own; none of the parent
# trees (repo root, src/) may be referenced. A shell glob over
# `${../../../src}/hosts/*/scripts` interpolates all of src/, which makes every
# edit anywhere under src/ a new input here — re-keying this derivation and
# every nucleus-*-app wrapper built from it.
{ pkgs }:

let
  inherit (pkgs) lib;

  # Hosts are discovered at eval time so adding a host's scripts/ dir needs no
  # edit here; only directories that exist are interpolated.
  hostScriptTrees =
    map
      (host: {
        inherit host;
        scripts = ../../hosts + "/${host}/scripts";
      })
      (
        lib.filter (host: builtins.pathExists (../../hosts + "/${host}/scripts")) (
          builtins.attrNames (builtins.readDir ../../hosts)
        )
      );
in
pkgs.runCommand "nucleus-script-tree"
  {
    preferLocalBuild = true;
  }
  ''
    mkdir -p "$out/src"
    cp -r "${../../scripts}" "$out/src/scripts"
    cp -r "${../../platforms}" "$out/src/platforms"
    ${lib.concatMapStrings (entry: ''
      mkdir -p "$out/src/hosts/${entry.host}"
      cp -r "${entry.scripts}" "$out/src/hosts/${entry.host}/scripts"
    '') hostScriptTrees}
    chmod -R +x "$out"
  ''
