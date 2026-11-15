# modules/lib/apple-sdk-enhanced.nix: Enhanced apple-sdk with real tool symlinks.
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
    # WHY: Homebrew 7.0.13 treats a non-CLT developer dir selected via
    # xcode-select as Xcode and requires a readable Xcode version >= 27.0 on
    # macOS 27. It detects that version from <prefix>.parent/version.plist or
    # by running <prefix>/usr/bin/xcodebuild -version. The enhanced Nix SDK has
    # no real Xcode/CLT, so we provide a minimal xcodebuild identity shim for
    # version detection instead of installing/enabling Apple CLT or a real
    # Xcode as the default developer dir.
    (pkgs.writeTextFile {
      name = "apple-sdk-xcodebuild-shim";
      destination = "/usr/bin/xcodebuild";
      executable = true;
      text = ''
        #!/bin/sh
        if [ "''${1-}" = "-version" ]; then
          printf '%s\n' "Xcode 27.0" "Build version 17A324"
          exit 0
        fi
        echo "xcodebuild: compatibility shim for Nix apple-sdk-enhanced; no real Xcode is installed" >&2
        exit 1
      '';
    })
  ];
}
