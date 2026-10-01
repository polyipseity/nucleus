# src/modules/lib/script-tree.nix - one derivation bundling src/scripts/,
# src/platforms/, and each host's scripts/ under $out/src/, so bundled paths stay
# repo-root-relative. Shellcheck runs in nucleus-check sh / CI, not at build time.
#
# WHY: each directory is interpolated on its own and no parent tree is
# referenced. A glob over `${../../../src}/hosts/*/scripts` interpolates all of
# src/, which re-keys this derivation and every nucleus-*-app wrapper on any
# edit under src/.
{ pkgs }:

let
  inherit (pkgs) lib;

  # Eval-time discovery: a new host scripts/ dir needs no edit here, and only
  # directories that exist are interpolated.
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
