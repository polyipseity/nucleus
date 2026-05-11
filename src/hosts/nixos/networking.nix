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
  # Titlecase hostname preserves consistent local discovery and machine identity
  # semantics for the NixOS host.
  networking.hostName = "NixOS";
  # Use NetworkManager for DHCP/Wi-Fi instead of the legacy wpa_supplicant setup.
  networking.networkmanager.enable = true;

  # Wake-on-LAN parity with macOS (pmset womp=1) and Windows (WakeOnMagicPacket).
  # The NixOS declarative option is interface-name-specific:
  #   networking.interfaces."<iface>".wakeOnLan.enable = true;
  # Discover the primary wired interface name with:
  #   ip -o link show | awk '/ether/ {print $2}' | tr -d ':'
  # Then add the option above with the real name and remove this comment.
  # Until then, see src/hosts/nixos/MANUAL.md for the manual enablement step.
}
