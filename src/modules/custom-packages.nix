# modules/custom-packages.nix — packages built from upstream sources.
#
# Builds tools directly from their upstream git repositories or prebuilt
# artifacts using Nix fetchers with pinned revisions.  Applies to all users
# (environment.systemPackages) on NixOS/macOS and per-user (home.packages) on
# standalone Home Manager.
#
# Adding a new custom package:
#   1. Add a derivation using pkgs.fetchFromGitHub or pkgs.fetchurl.
#   2. Compute the SRI hash: nix-prefetch-url <url>
#   3. Add the derivation to the package list below.
{
  config,
  lib,
  pkgs,
  options,
  ...
}:

let
  equaliser = pkgs.stdenv.mkDerivation rec {
    pname = "equaliser";
    version = "1.3.3";

    sourceRoot = ".";

    nativeBuildInputs = [ pkgs.undmg ];

    src = pkgs.fetchurl {
      url = "https://github.com/cvknage/equaliser/releases/download/v${version}/Equaliser-${version}.dmg";
      hash = "sha256-L/W2Vw2DPkTzeHG2wciN7ORQYRN35dM5sHmnBTkzlLI=";
    };

    installPhase = ''
      mkdir -p $out/Applications
      cp -r *.app $out/Applications/
    '';

    meta = {
      description = "System-wide parametric equaliser for Apple Silicon";
      homepage = "https://github.com/cvknage/equaliser";
      license = lib.licenses.gpl3Only;
      platforms = [ "aarch64-darwin" ];
    };
  };

  camillagui-backend = pkgs.stdenv.mkDerivation rec {
    pname = "camillagui-backend";
    version = "4.1.0";

    # Select the platform-specific prebuilt PyInstaller bundle.
    src =
      if pkgs.stdenv.isDarwin then
        if pkgs.stdenv.isAarch64 then
          pkgs.fetchurl {
            url = "https://github.com/HEnquist/camillagui-backend/releases/download/v${version}/bundle_macos_aarch64.tar.gz";
            hash = "sha256-CdoLZUrvqhyYPwIIUk2av3aOihOuRnDWm8ZcF/1LT2M=";
          }
        else
          pkgs.fetchurl {
            url = "https://github.com/HEnquist/camillagui-backend/releases/download/v${version}/bundle_macos_intel.tar.gz";
            hash = "sha256-RUDHi8Bbhpdydr6lGI+TCNTMqtlUyoJgtH0rG2x01kE=";
          }
      else if pkgs.stdenv.isAarch64 then
        pkgs.fetchurl {
          url = "https://github.com/HEnquist/camillagui-backend/releases/download/v${version}/bundle_linux_aarch64.tar.gz";
          hash = "sha256-mlQVtE3aWEePGN6f1XLt8JL2Wf1eRcvoCG/1ZI3Aidc=";
        }
      else
        pkgs.fetchurl {
          url = "https://github.com/HEnquist/camillagui-backend/releases/download/v${version}/bundle_linux_amd64.tar.gz";
          hash = "sha256-hv083ldQOPMS7ee60JENxeRrl0yvwEjCYRXsPLn1R5I=";
        };

    sourceRoot = "camillagui_backend";

    installPhase = ''
      mkdir -p $out/libexec/camillagui-backend $out/bin
      cp -r * $out/libexec/camillagui-backend/
      ln -s $out/libexec/camillagui-backend/camillagui_backend $out/bin/camillagui-backend
    '';

    meta = {
      description = "Web GUI for CamillaDSP";
      homepage = "https://github.com/HEnquist/camillagui-backend";
      license = lib.licenses.mit;
      platforms = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
    };
  };
in
{
  config = lib.mkMerge [
    (lib.optionalAttrs (options ? environment && options.environment ? systemPackages) {
      environment.systemPackages = lib.optionals pkgs.stdenv.isDarwin [ equaliser ];
    })
    (lib.optionalAttrs (options ? home && options.home ? packages) {
      home.packages = lib.optionals pkgs.stdenv.isDarwin [ equaliser ];
    })
    (lib.optionalAttrs (options ? environment && options.environment ? systemPackages) {
      environment.systemPackages = [ camillagui-backend ];
    })
    (lib.optionalAttrs (options ? home && options.home ? packages) {
      home.packages = [ camillagui-backend ];
    })
  ];
}
