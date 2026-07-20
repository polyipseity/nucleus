# modules/lib/apple-sdk-enhanced.nix — Enhanced apple-sdk with real tool symlinks.
#
# The original apple-sdk has an empty usr/bin/ (only xcrun → xcbuild).
# This layers symlinks to real nixpkgs tools so that every xcrun shim
# (/usr/bin/python3, /usr/bin/git, etc.) resolves via DEVELOPER_DIR/usr/bin/<tool>.
{ pkgs, lib }:
let
  appleSdkTools = import ./apple-sdk-tools.nix { inherit pkgs; };
in
pkgs.symlinkJoin {
  name = "apple-sdk-enhanced";
  paths = [
    pkgs.apple-sdk # original: headers, platforms, xcrun → xcbuild
    (pkgs.runCommand "apple-sdk-enhanced-usr-bin" { } ''
      mkdir -p "$out/usr/bin"
      ${lib.concatStringsSep "\n" (
        builtins.map (
          name:
          if appleSdkTools.allTools.${name} != null then
            "ln -s ${
              lib.strings.escapeShellArg appleSdkTools.allTools.${name}
            } \"$out/usr/bin/${lib.strings.escapeShellArg name}\""
          else
            ""
        ) (builtins.attrNames appleSdkTools.allTools)
      )}
    '')
  ];
}
