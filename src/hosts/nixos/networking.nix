# nixos/networking.nix — Hostname and network management for the NixOS host.
{ ... }:
{
  # mDNS/Bonjour discovery parity with macOS for easier local host discovery.
  services.avahi = {
    enable = true;
    nssmdns4 = true;
    openFirewall = true;
    publish = {
      enable = true;
      userServices = true;
    };
  };

  # Enable the nftables-based stateful firewall; blocks unsolicited inbound.
  networking.firewall.enable = true;
  networking.hostName = "nixos";
  # Use NetworkManager for DHCP/Wi-Fi instead of the legacy wpa_supplicant setup.
  networking.networkmanager.enable = true;
}
