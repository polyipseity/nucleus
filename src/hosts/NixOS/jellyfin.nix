# NixOS/jellyfin.nix — Host-level singleton Jellyfin service.
#
# Jellyfin must run once per host (shared across all users). Running it as a
# system service avoids one-instance-per-Home-Manager-user fanout.
{ ... }:
{
  services.jellyfin = {
    enable = true;
    openFirewall = true;
  };
}
