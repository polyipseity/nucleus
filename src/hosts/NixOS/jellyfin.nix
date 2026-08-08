# NixOS/jellyfin.nix — Host-level singleton Jellyfin service + HTTPS ingress.
#
# Jellyfin must run once per host (shared across all users). Running it as a
# system service avoids one-instance-per-Home-Manager-user fanout.
#
# HTTPS provided by nucleus.httpsProxy via the NixOS/https-proxy.nix mapping.
#
# Sources:
# - https://jellyfin.org/docs/general/post-install/networking/reverse-proxy/
{ ... }:
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
}
