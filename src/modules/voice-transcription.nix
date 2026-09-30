# src/modules/voice-transcription.nix — local speech-to-text via whisper-cpp.
#
# The package itself is declared once in `managedPackages` (core.nix) and, on
# Windows, in the Scoop list of src/modules/packages/desired.json. This module
# owns the part no package manager ships: the ggml weights.
#
# WHY whisper.cpp and not faster-whisper: hermes-agent.nix already drops the
# hermes `voice` dependency group because ctranslate2, onnxruntime, torch and
# transformers build from source for 30-80 minutes on aarch64-darwin. whisper.cpp
# is C++ and nixpkgs builds it in seconds on every POSIX platform.
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

  # The lockfile is the only pin authority for these weights: nothing in
  # nixpkgs, Scoop or Homebrew ships them, and a HuggingFace `main` ref is
  # mutable. A revision-pinned URL plus an SRI hash in the lockfile makes the
  # fetch reproducible. The POSIX and Windows lockfile enforcement probes both
  # read this section, and each host's MANUAL documents this path.
  lockfile = builtins.fromJSON (builtins.readFile ../lockfiles/lockfile.json);

  models = lib.mapAttrsToList (file: pin: {
    inherit file;
    # pkgs.fetchurl enforces `pin.hash` when the store path is realised, so
    # the activation script can trust the source it is handed.
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
      # A `true` default keeps this independent of the package registry: the two
      # are tied together by tests/modules/voice-transcription-tests.nix, which
      # fails when the lockfile section and managedPackages disagree.
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
