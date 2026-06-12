# modules/https-proxy.nix — Local Caddy HTTPS proxy for loopback services.
#
# Defines nucleus.httpsProxy.virtualHosts and (on macOS) creates a single
# launchd daemon that runs Caddy with an auto-generated Caddyfile.
# On NixOS the option feeds into services.caddy via NixOS/https-proxy.nix.
#
# Sources:
# - https://caddyserver.com/docs/caddyfile/directives/reverse_proxy
# - https://caddyserver.com/docs/caddyfile/directives/tls
{
  config,
  lib,
  pkgs,
  username ? null,
  ...
}:
let
  inherit (lib) mkIf mkOption types;
  cfg = config.nucleus.httpsProxy;

  servicesJSON = builtins.fromJSON (builtins.readFile ./services.json);
  caddyAdminAddr = "${servicesJSON.caddy.network.admin.host}:${toString servicesJSON.caddy.network.admin.port}";

  # Generate a Caddyfile from all configured virtual hosts.
  caddyfile = pkgs.writeText "https-proxy.Caddyfile" (
    let
      globalConfig = ''
        {
          admin ${caddyAdminAddr}
          auto_https disable_redirects
        }
      '';

      virtualHostConfigs = lib.mapAttrsToList (name: vh: ''
        https://${vh.hostname}:${toString vh.listenPort} {
          bind 127.0.0.1 ::1
          tls internal
          reverse_proxy ${vh.upstreamHost}:${toString vh.upstreamPort}
        ${lib.optionalString (vh.extraConfig != "") (
          lib.concatMapStringsSep "\n" (line: "  ${line}") (lib.splitString "\n" vh.extraConfig)
        )}
        }
      '') cfg.virtualHosts;
    in
    globalConfig + "\n" + builtins.concatStringsSep "\n" virtualHostConfigs
  );

  proxyDaemon = pkgs.writeShellScript "https-proxy-daemon" ''
    set -eu

    state_root="/Users/Shared/https-proxy"
    caddy_root="$state_root/caddy"
    caddy_config_dir="$caddy_root/config"
    caddy_data_dir="$caddy_root/data"
    log_dir="$state_root/log"

    mkdir -p "$caddy_config_dir" "$caddy_data_dir" "$log_dir"

    export XDG_CONFIG_HOME="$caddy_config_dir"
    export XDG_DATA_HOME="$caddy_data_dir"

    exec ${pkgs.caddy}/bin/caddy run --config ${caddyfile} --adapter caddyfile
  '';
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

  config = mkIf pkgs.stdenv.isDarwin (
    let
      systemLogDir = config.nucleus.logging.systemLogDir;
    in
    {
      launchd.daemons.httpsProxy = {
        serviceConfig = {
          ProgramArguments = [ "${proxyDaemon}" ];
          KeepAlive = true;
          RunAtLoad = true;
          UserName = username;
          StandardOutPath = "${systemLogDir}/https-proxy/stdout.log";
          StandardErrorPath = "${systemLogDir}/https-proxy/stderr.log";
        };
      };
    }
  );
}
