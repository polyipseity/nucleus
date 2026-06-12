# NixOS/https-proxy.nix — Map nucleus.httpsProxy.virtualHosts to services.caddy.
#
# Enables the NixOS Caddy module with the admin endpoint and per-virtual-host
# TLS termination so all host-shared services declared via
# nucleus.httpsProxy get Caddy HTTPS ingress.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (lib) mkIf;
  cfg = config.nucleus.httpsProxy;

  servicesJSON = builtins.fromJSON (builtins.readFile ../../modules/services.json);
  caddyAdminAddr = "${servicesJSON.caddy.network.admin.host}:${toString servicesJSON.caddy.network.admin.port}";
in
mkIf (cfg.virtualHosts != { }) {
  services.caddy = {
    enable = true;
    globalConfig = ''
      admin ${caddyAdminAddr}
      auto_https disable_redirects
    '';
    virtualHosts = builtins.listToAttrs (
      map (
        name:
        let
          vh = cfg.virtualHosts.${name};
          addr = "https://${vh.hostname}:${toString vh.listenPort}";
        in
        {
          name = addr;
          value = {
            extraConfig = ''
              bind 127.0.0.1 ::1
              tls internal
              reverse_proxy ${vh.upstreamHost}:${toString vh.upstreamPort}
            ''
            + (lib.optionalString (vh.extraConfig != "") "\n${vh.extraConfig}\n");
          };
        }
      ) (builtins.attrNames cfg.virtualHosts)
    );
  };
}
