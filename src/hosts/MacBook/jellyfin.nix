# MacBook/jellyfin.nix — Host-level singleton Jellyfin daemon.
#
# Runs one shared Jellyfin instance for the whole host instead of one
# LaunchAgent per Home Manager user.
{ pkgs, username, ... }:
let
  jellyfinDaemon = pkgs.writeShellScript "jellyfin-daemon" ''
    set -eu

    state_root="/Users/Shared/Jellyfin"
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
in
{
  launchd.daemons.jellyfin = {
    command = "${jellyfinDaemon}";
    serviceConfig = {
      KeepAlive = true;
      RunAtLoad = true;
      UserName = username;
      StandardOutPath = "/Users/Shared/Jellyfin/log/launchd.out.log";
      StandardErrorPath = "/Users/Shared/Jellyfin/log/launchd.err.log";
    };
  };
}
