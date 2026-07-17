# NixOS/jellyfin.nix — Host-level singleton Jellyfin service + HTTPS ingress.
#
# Jellyfin must run once per host (shared across all users). Running it as a
# system service avoids one-instance-per-Home-Manager-user fanout.
#
# HTTPS provided by nucleus.httpsProxy via the NixOS/https-proxy.nix mapping.
#
# Sources:
# - https://jellyfin.org/docs/general/post-install/networking/reverse-proxy/
{ lib, ... }:
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
  # WHY a separate script instead of inline shell: see the rationale in
  # src/scripts/services/jellyfin-sync.sh header — this is runtime imperative API
  # convergence that Nix's build-time model cannot express.
  system.activationScripts.jellyfin-sync = lib.mkAfter ''
    jellyfin_repo_root="''${NUCLEUS_REPO_ROOT:-}"
    if [ -n "$jellyfin_repo_root" ] && [ -f "$jellyfin_repo_root/src/scripts/services/jellyfin-sync.sh" ]; then
      NUCLEUS_REPO_ROOT="$jellyfin_repo_root" sh "$jellyfin_repo_root/src/scripts/services/jellyfin-sync.sh"
    fi
  '';
}
