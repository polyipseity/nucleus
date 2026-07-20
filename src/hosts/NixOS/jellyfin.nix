# NixOS/jellyfin.nix — Host-level singleton Jellyfin service + HTTPS ingress.
#
# Jellyfin must run once per host (shared across all users). Running it as a
# system service avoids one-instance-per-Home-Manager-user fanout.
#
# HTTPS provided by nucleus.httpsProxy via the NixOS/https-proxy.nix mapping.
#
# Sources:
# - https://jellyfin.org/docs/general/post-install/networking/reverse-proxy/
{
  config,
  lib,
  pkgs,
  ...
}:
let
  jellyfinHttpPort = 8096;
in
{
  services.jellyfin = {
    enable = true;
    # Keep direct HTTP port off the host firewall; HTTPS is provided by Caddy.
    openFirewall = false;
  };

  nucleus.httpsProxy.virtualHosts.jellyfin = {
    listenPort = 8920;
    upstreamPort = jellyfinHttpPort;
  };

  # Activation script: converge Jellyfin accounts and libraries after the
  # Jellyfin service is running.  Mirrors the Darwin postActivation fragment but
  # uses a named script (nixos-specific option).
  #
  # WHY embedded via readFile with NUCLEUS_REPO_ROOT token (not runtime sh):
  # see the rationale in activation.nix (MacBook) — the script is
  # self-contained when NUCLEUS_REPO_ROOT is set at build time, eliminating
  # the runtime file-system dependency on the repo checkout path.
  system.activationScripts.jellyfin-sync = lib.mkAfter (
    let
      repoRoot = builtins.getEnv "NUCLEUS_REPO_ROOT";
    in
    ''
      NUCLEUS_REPO_ROOT="${repoRoot}"; export NUCLEUS_REPO_ROOT
      PATH="${pkgs.sops}/bin:$PATH"; export PATH
      ${builtins.readFile ../../scripts/services/jellyfin-sync.sh}
    ''
  );
}
