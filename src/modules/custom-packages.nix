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
      hash = "sha256-1cll6cwhb9vrn0wx7rbp2dhm1r7cip4c3dkig3rl8gl31mbvdx9g";
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
in
{
  config = lib.mkMerge [
    (lib.optionalAttrs (options ? environment && options.environment ? systemPackages) {
      environment.systemPackages = lib.optionals pkgs.stdenv.isDarwin [ equaliser ];
    })
    (lib.optionalAttrs (options ? home && options.home ? packages) {
      home.packages = lib.optionals pkgs.stdenv.isDarwin [ equaliser ];
    })
  ];
}
