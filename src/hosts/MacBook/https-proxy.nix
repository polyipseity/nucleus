# hosts/MacBook/https-proxy.nix — HTTPS proxy launchd service.
#
# Service-manager-specific fragment imported alongside the shared module.
# The shared option definitions are in src/modules/https-proxy.nix.
{
  config,
  lib,
  pkgs,
  username,
  ...
}:

let
  servicesJSON = builtins.fromJSON (builtins.readFile ../../modules/services.json);
  caddyAdminAddr = "${servicesJSON.caddy.network.admin.host}:${toString servicesJSON.caddy.network.admin.port}";
  cfg = config.nucleus.httpsProxy;

  # Generate a Caddyfile from all configured virtual hosts.
  caddyfile = pkgs.writeText "https-proxy.Caddyfile" (
    let
      globalConfig = ''
        {
          admin ${caddyAdminAddr}
          auto_https disable_redirects
        }
      '';

      virtualHostConfigs = lib.mapAttrsToList (_name: vh: ''
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

  systemLogDir = config.nucleus.logging.systemLogDir;
in
{
  launchd.daemons.httpsProxy = {
    serviceConfig = {
      ProgramArguments = [ "${proxyDaemon}" ];
      KeepAlive = true;
      RunAtLoad = true;
      UserName = username;
      EnvironmentVariables =
        (import ../../modules/lib/env-vars.nix {
          inherit
            config
            pkgs
            lib
            username
            ;
        }).toMacOSDaemonEnv;
      StandardOutPath = "${systemLogDir}/caddy/stdout.log";
      StandardErrorPath = "${systemLogDir}/caddy/stderr.log";
    };
  };
}
