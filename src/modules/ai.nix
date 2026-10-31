# Local AI inference baseline (Ollama, oterm, LiteLLM proxy).
# Ollama is installed globally via the managedPackages registry in core.nix;
# this module provides the per-user oterm client. Gated at the host level by
# which user's Home Manager config imports this module.
{ nixpkgs, pkgs, ... }:
let
  appleSiliconDarwin =
    pkgs.stdenv.hostPlatform.isDarwin && pkgs.stdenv.hostPlatform.system == "aarch64-darwin";

  otermPkg =
    if appleSiliconDarwin then
      let
        permissivePkgs = import nixpkgs {
          inherit (pkgs.stdenv.hostPlatform) system;
          config.allowUnfree = true;
          config.allowUnsupportedSystem = true;
          overlays = [
            (_final: prev: {
              # WHY: mirror the mkPkgs override so fastmcp/oterm build against
              # mcp_1 instead of the broken mcp >= 2 path (see flake.nix).
              python314Packages = prev.python314Packages.overrideScope (pyfinal: pyprev: {
                # WHY: oterm (and fastmcp-slim) must agree on one mcp version;
                # alias mcp to mcp_1 so no duplicate mcp appears in the closure.
                mcp = pyfinal.mcp_1;
              });
            })
          ];
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
  # (src/modules/lib/env-secrets.nix) and injected via home.sessionVariables.
}
