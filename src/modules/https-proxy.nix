# Local Caddy HTTPS proxy for loopback services.
{ lib, ... }:
let
  inherit (lib) mkOption types;
in
{
  options.nucleus.httpsProxy = {
    virtualHosts = mkOption {
      type = types.attrsOf (
        types.submodule {
          options = {
            hostname = mkOption {
              type = types.str;
              default = "localhost";
              description = "Hostname the virtual host responds to.";
            };

            listenPort = mkOption {
              type = types.port;
              description = "Local HTTPS listen port.";
            };

            upstreamHost = mkOption {
              type = types.str;
              default = "127.0.0.1";
              description = "Upstream HTTP host.";
            };

            upstreamPort = mkOption {
              type = types.port;
              description = "Upstream HTTP port.";
            };

            extraConfig = mkOption {
              type = types.lines;
              default = "";
              description = "Extra Caddyfile directives for this virtual host.";
            };
          };
        }
      );
      default = { };
      description = "Virtual hosts for the local Caddy HTTPS proxy.";
    };
  };

  config = { };
}
