# hosts/nixos/hardware/gpu.nix — Graphics driver baseline for this NixOS host.
#
# Keep generic modesetting until host-specific hardware configuration is
# generated so fresh installs boot reliably across virtualized environments.
{ ... }:
{
  services.xserver.videoDrivers = [ "modesetting" ];
}
