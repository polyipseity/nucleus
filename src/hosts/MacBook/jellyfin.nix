# MacBook/jellyfin.nix — Host-level singleton Jellyfin daemon + HTTPS ingress.
#
# Runs one shared Jellyfin instance for the whole host instead of one
# LaunchAgent per Home Manager user.
#
# HTTPS is provided by the shared https-proxy module; this file only declares
# the Jellyfin daemon and the virtual host entry for the proxy.
#
# Sources:
# - https://jellyfin.org/docs/general/post-install/networking/reverse-proxy/
{
  config,
  lib,
  pkgs,
  username,
  ...
}:
let
  jellyfinHttpPort = 8096;
  jellyfinStateRoot = "/Users/Shared/Jellyfin";

  envVars = import ../../modules/lib/env-vars.nix {
    inherit
      config
      pkgs
      lib
      username
      ;
  };
  resolveValue = name: envVars.resolveValue name "macOS";
  daemonEnv = lib.filterAttrs (_name: value: value != null) {
    NIX_SSL_CERT_FILE = resolveValue "NIX_SSL_CERT_FILE";
    NUCLEUS_HOST = resolveValue "NUCLEUS_HOST";
  };

  jellyfinDaemon = pkgs.writeShellScript "jellyfin-daemon" ''
    set -eu

    state_root="${jellyfinStateRoot}"
    config_dir="$state_root/config"
    data_dir="$state_root/data"
    cache_dir="$state_root/cache"
    log_dir="${config.nucleus.logging.systemLogDir}/jellyfin-app"

    mkdir -p "$config_dir" "$data_dir" "$cache_dir" "$log_dir"

    exec ${pkgs.jellyfin}/bin/jellyfin \
      --configdir "$config_dir" \
      --datadir "$data_dir" \
      --cachedir "$cache_dir" \
      --logdir "$log_dir"
  '';
in
{
  launchd.daemons.jellyfin = {
    serviceConfig = {
      ProgramArguments = [ "${jellyfinDaemon}" ];
      KeepAlive = true;
      RunAtLoad = true;
      UserName = username;
      EnvironmentVariables = daemonEnv;
      StandardOutPath = "${config.nucleus.logging.systemLogDir}/jellyfin/stdout.log";
      StandardErrorPath = "${config.nucleus.logging.systemLogDir}/jellyfin/stderr.log";
    };
  };

  nucleus.httpsProxy.virtualHosts.jellyfin = {
    listenPort = 8920;
    upstreamPort = jellyfinHttpPort;
  };
}
