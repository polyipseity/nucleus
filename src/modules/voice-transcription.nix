# src/modules/voice-transcription.nix - local speech-to-text via whisper-cpp.
#
# The package is declared in core.nix managedPackages and, on Windows, in the
# Scoop list of src/modules/packages/desired.json. This module owns the ggml
# weights, which no package manager ships.
#
# WHY whisper.cpp: hermes-agent.nix already drops the hermes `voice` group
# because ctranslate2, onnxruntime, torch and transformers build from source for
# 30-80 minutes on aarch64-darwin.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (lib) mkIf mkEnableOption;

  cfg = config.nucleus.voiceTranscription;

  activationBundle = pkgs.callPackage ./lib/script-tree.nix { };

  nucleusUserRoot =
    if pkgs.stdenv.hostPlatform.isDarwin then
      "${config.home.homeDirectory}/Library/Application Support/nucleus"
    else
      "${config.home.homeDirectory}/.local/share/nucleus";

  # The lockfile is the only pin authority here: a HuggingFace `main` ref is
  # mutable, so the URL carries a revision plus an SRI hash. Both host probes
  # read this section.
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
  }) (lockfile.whisper or { });
in
{
  options.nucleus.voiceTranscription.enable =
    mkEnableOption "deployment of the whisper ggml model weights"
    // {
      # A `true` default keeps this independent of the package registry;
      # tests/modules/voice-transcription-tests.nix ties the two together.
      default = true;
    };

  config = mkIf cfg.enable {
    home.activation.fetch-whisper-models = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      "${activationBundle}/src/scripts/ai/fetch-whisper-models.sh" \
        "${nucleusUserRoot}/models" \
        "${pkgs.coreutils}/bin/sha256sum" \
        "${pkgs.jq}/bin/jq" \
        '${builtins.toJSON models}'
    '';
  };
}
