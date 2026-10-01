# NixOS/networking.nix - hostname and network management.
{ ... }: {
  # mDNS/Bonjour discovery, matching macOS for local host discovery.
  # Source: https://mynixos.com/nixpkgs/option/services.avahi.enable
  services.avahi = {
    enable = true;
    nssmdns4 = true;
    openFirewall = true;
    publish = {
      enable = true;
      userServices = true;
    };
  };

  # Stateful firewall, blocks unsolicited inbound.
  # Source: https://mynixos.com/nixpkgs/option/networking.firewall.enable
  networking.firewall.enable = true;
  # Titlecase hostname keeps local discovery and machine identity consistent.
  networking.hostName = "NixOS";
  # NetworkManager for DHCP/Wi-Fi, not the legacy wpa_supplicant setup.
  # Source: https://mynixos.com/nixpkgs/option/networking.networkmanager.enable
  networking.networkmanager.enable = true;
  # Randomize MAC per Wi-Fi connect.
  # Source: https://mynixos.com/nixpkgs/option/networking.networkmanager.wifi.macAddress
  networking.networkmanager.wifi.macAddress = "random";
  # Randomize MAC while scanning.
  # Source: https://mynixos.com/nixpkgs/option/networking.networkmanager.wifi.scanRandMacAddress
  networking.networkmanager.wifi.scanRandMacAddress = true;

  # Wake-on-LAN parity with macOS (pmset womp=1) and Windows. The NixOS option is
  # interface-name-specific, so it stays manual for now:
  #   ip -o link show | awk '/ether/ {print $2}' | tr -d ':'
  # then networking.interfaces."<iface>".wakeOnLan.enable = true. See
  # src/hosts/NixOS/MANUAL.md.
}
