# Local AI inference baseline (Ollama, oterm, LiteLLM proxy).
# Ollama is installed globally via the managedPackages registry in core.nix;
# this module provides the per-user oterm client. Gated at the host level by
# which user's Home Manager config imports this module.
{ nixpkgs, pkgs, ... }:
let
  appleSiliconDarwin = pkgs.stdenv.isDarwin && pkgs.stdenv.hostPlatform.system == "aarch64-darwin";

  otermPkg =
    if appleSiliconDarwin then
      let
        permissivePkgs = import nixpkgs {
          inherit (pkgs.stdenv.hostPlatform) system;
          config.allowUnfree = true;
          config.allowUnsupportedSystem = true;
        };
      in
      permissivePkgs.oterm
    else
      pkgs.oterm;
in
{
  home.packages = [
    otermPkg
  ];

  # OLLAMA_HOST is defined in the centralized env var catalog
  # (src/modules/lib/env-catalog.nix) and injected via home.sessionVariables.
}
