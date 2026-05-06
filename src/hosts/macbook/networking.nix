# macbook/networking.nix — Network identity and firewall policy for the MacBook.
{ ... }:
{
  # Application-level firewall: block unsigned inbound connections while
  # allowing binaries that are code-signed by a trusted authority.
  networking.applicationFirewall = {
    allowSigned = true;       # allow signed apps to accept inbound connections
    blockAllIncoming = false; # per-app blocking is sufficient; a blanket block
                              # would break screen sharing and remote desktop
    enable = true;
    enableStealthMode = false; # stealth mode hides the host from network scans;
                               # disabled to keep remote-desktop discovery working
  };

  # Enable macOS Screen Sharing (VNC/ARD protocol) as the remote-desktop server
  # for this host.  macOS does not ship a native RDP server; Screen Sharing is
  # the platform equivalent and is accessible from Microsoft Remote Desktop
  # clients (which support connecting to Macs) as well as any VNC client.
  # blockAllIncoming = false in the firewall config already permits the inbound
  # VNC port (5900); no additional firewall rule is needed.
  services.screensharing.enable = true;

  networking.computerName = "macbook";
  networking.hostName = "macbook";
  networking.localHostName = "macbook";
}
