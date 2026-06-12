# MacBook/jellyfin.nix — Host-level singleton Jellyfin daemon + HTTPS ingress.
#
# Runs one shared Jellyfin instance for the whole host instead of one
# LaunchAgent per Home Manager user.
#
# HTTPS pattern: terminate TLS at a local reverse proxy and keep Jellyfin on
# loopback HTTP upstream. This is the same pattern we can reuse for other
# host-shared services that need HTTPS.
#
# Sources:
# - https://jellyfin.org/docs/general/post-install/networking/reverse-proxy/
# - https://caddyserver.com/docs/caddyfile/directives/reverse_proxy
# - https://caddyserver.com/docs/caddyfile/directives/tls
{
  config,
  pkgs,
  username,
  ...
}:
let
  servicesJSON = builtins.fromJSON (builtins.readFile ../../modules/services.json);
  caddyAdminAddr = "${servicesJSON.caddy.network.admin.host}:${toString servicesJSON.caddy.network.admin.port}";

  jellyfinHttpPort = 8096;
  jellyfinHttpsPort = 8920;
  jellyfinStateRoot = "/Users/Shared/Jellyfin";

  jellyfinDaemon = pkgs.writeShellScript "jellyfin-daemon" ''
    set -eu

    state_root="${jellyfinStateRoot}"
    config_dir="$state_root/config"
    data_dir="$state_root/data"
    cache_dir="$state_root/cache"
    log_dir="$state_root/log"

    mkdir -p "$config_dir" "$data_dir" "$cache_dir" "$log_dir"

    exec ${pkgs.jellyfin}/bin/jellyfin \
      --configdir "$config_dir" \
      --datadir "$data_dir" \
      --cachedir "$cache_dir" \
      --logdir "$log_dir"
  '';

  jellyfinHttpsCaddyfile = pkgs.writeText "jellyfin-https.Caddyfile" ''
    {
      # Keep the admin API local-only; manual trust uses this endpoint.
      admin ${caddyAdminAddr}
      # Avoid implicit HTTP redirect listener on :80 for localhost-only service.
      auto_https disable_redirects
    }

    https://localhost:${toString jellyfinHttpsPort} {
      bind 127.0.0.1 ::1
      tls internal
      reverse_proxy 127.0.0.1:${toString jellyfinHttpPort}
    }
  '';

  jellyfinHttpsProxyDaemon = pkgs.writeShellScript "jellyfin-https-proxy-daemon" ''
    set -eu

    state_root="${jellyfinStateRoot}"
    caddy_root="$state_root/caddy"
    caddy_config_dir="$caddy_root/config"
    caddy_data_dir="$caddy_root/data"
    log_dir="$state_root/log"

    mkdir -p "$caddy_config_dir" "$caddy_data_dir" "$log_dir"

    export XDG_CONFIG_HOME="$caddy_config_dir"
    export XDG_DATA_HOME="$caddy_data_dir"

    exec ${pkgs.caddy}/bin/caddy run --config ${jellyfinHttpsCaddyfile} --adapter caddyfile
  '';
in
{
  launchd.daemons.jellyfin = {
    serviceConfig = {
      ProgramArguments = [ "${jellyfinDaemon}" ];
      KeepAlive = true;
      RunAtLoad = true;
      UserName = username;
      StandardOutPath = "${config.nucleus.logging.systemLogDir}/jellyfin/stdout.log";
      StandardErrorPath = "${config.nucleus.logging.systemLogDir}/jellyfin/stderr.log";
    };
  };

  launchd.daemons.jellyfinHttpsProxy = {
    serviceConfig = {
      ProgramArguments = [ "${jellyfinHttpsProxyDaemon}" ];
      KeepAlive = true;
      RunAtLoad = true;
      UserName = username;
      StandardOutPath = "${config.nucleus.logging.systemLogDir}/jellyfin-https/stdout.log";
      StandardErrorPath = "${config.nucleus.logging.systemLogDir}/jellyfin-https/stderr.log";
    };
  };
}
