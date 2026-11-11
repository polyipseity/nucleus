# src/modules/deepfilternet.nix - DeepFilterNet3 ONNX model weights for deep-filter.
#
# The package/CLI is declared separately in the host package registries. This
# module owns the ONNX model tarball, which no package manager ships.
#
# Ruling: deep-filter consumes the ONNX tar.gz model (enc.onnx, erb_dec.onnx,
# df_dec.onnx, config.ini), not the PyTorch zip; pin the v0.5.6 tag commit
# revision in the URL and deploy as a stable filename under <nucleus USER root>/models.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (lib) mkIf mkEnableOption;

  cfg = config.nucleus.deepFilterNet;

  activationBundle = pkgs.callPackage ./lib/script-tree.nix { };

  nucleusUserRoot =
    if pkgs.stdenv.hostPlatform.isDarwin then
      "${config.home.homeDirectory}/Library/Application Support/nucleus"
    else
      "${config.home.homeDirectory}/.local/share/nucleus";

  # The lockfile is the only pin authority here: the URL carries the revision
  # plus an SRI hash. Both host probes read this section.
  lockfile = builtins.fromJSON (builtins.readFile ../lockfiles/lockfile.json);

  models = lib.mapAttrsToList (file: pin: {
    inherit file;
    # pkgs.fetchurl enforces pin.hash at realise time, so the activation
    # script can trust the source it is handed.
    source =
      (pkgs.fetchurl {
        inherit (pin) url hash;
        name = file;
      }).outPath;
  }) (lockfile.deepfilternet or { });
in
{
  options.nucleus.deepFilterNet.enable =
    mkEnableOption "deployment of the DeepFilterNet3 ONNX model weights"
    // {
      # A `true` default keeps this independent of the package registry.
      default = true;
    };

  config = mkIf cfg.enable {
    home.activation.fetch-deepfilternet-models = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      "${activationBundle}/src/scripts/ai/fetch-deepfilternet-models.sh" \
        "${nucleusUserRoot}/models" \
        "${pkgs.coreutils}/bin/sha256sum" \
        "${pkgs.jq}/bin/jq" \
        '${builtins.toJSON models}'
    '';
  };
}
