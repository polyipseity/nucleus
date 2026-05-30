# NixOS/jellyfin.nix — Host-level singleton Jellyfin service + HTTPS ingress.
#
# Jellyfin must run once per host (shared across all users). Running it as a
# system service avoids one-instance-per-Home-Manager-user fanout.
#
# HTTPS pattern: terminate TLS at a local reverse proxy and keep Jellyfin on
# loopback HTTP upstream. This is reusable for future host-shared services.
#
# Sources:
# - https://jellyfin.org/docs/general/post-install/networking/reverse-proxy/
# - https://caddyserver.com/docs/caddyfile/directives/reverse_proxy
# - https://caddyserver.com/docs/caddyfile/directives/tls
{ ... }:
let
  jellyfinHttpPort = 8096;
  jellyfinHttpsPort = 8920;
in
{
  services.jellyfin = {
    enable = true;
    # Keep direct HTTP port off the host firewall; HTTPS is provided by Caddy.
    openFirewall = false;
  };

  services.caddy = {
    enable = true;
    globalConfig = ''
      # Avoid implicit HTTP redirect listener on :80 for localhost-only service.
      auto_https disable_redirects
    '';
    virtualHosts."https://localhost:${toString jellyfinHttpsPort}".extraConfig = ''
      bind 127.0.0.1 ::1
      tls internal
      reverse_proxy 127.0.0.1:${toString jellyfinHttpPort}
    '';
  };
}
