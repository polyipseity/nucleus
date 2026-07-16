# Local AI inference baseline (Ollama, oterm, LiteLLM proxy).
# Primary-user-only: unconditionally installs AI tooling; gated at the
# host level by which user's Home Manager config imports this module.
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
    pkgs.ollama
    otermPkg
  ];

  # OLLAMA_HOST is defined in the centralized env var catalog
  # (src/modules/lib/env-catalog.nix) and injected via home.sessionVariables.
}
