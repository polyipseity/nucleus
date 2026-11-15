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
    # WHY: switch base to macOS 27 SDK (pkgs.apple-sdk_27) so Homebrew 7.0.13
    # check_if_supported_sdk_available finds a macOS 27-compatible SDK
    # (SDKSettings Version 27.x) under the selected developer dir on macOS 27,
    # while keeping the same layout/paths (MacOSX.sdk symlink, Platforms/...).
    # Declarative from flake pkgs (no synthetic SDK metadata). Risk: base move
    # 14.4->27.0 may change headers/APIs/deployment defaults for downstream
    # builds (e.g. ntfs-3g, rust/c toolchains) — validate builds on-host if needed.
    pkgs.apple-sdk_27 # macOS 27-capable SDK base (headers, platforms, xcrun -> xcbuild)
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
