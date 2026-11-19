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

  bashShebang = import ./bash-shebang.nix { inherit pkgs; };
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
    chmod -R u+w "$out"
    ${bashShebang.rewriteBashShebang "$out/src"}
    chmod -R +x "$out"
  ''
