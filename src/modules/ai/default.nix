# Local AI inference baseline (Ollama, oterm, LiteLLM proxy).
# Primary-user-only: unconditionally installs AI tooling; gated at the
# host level by which user's Home Manager config imports this module.
{ nixpkgs, pkgs, ... }:
let
  servicesJSON = builtins.fromJSON (builtins.readFile ../services.json);
  litellmEndpoint = servicesJSON.litellm.network.default;

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

  home.sessionVariables = {
    OLLAMA_HOST = "${litellmEndpoint.host}:${toString litellmEndpoint.port}";
  };
}
