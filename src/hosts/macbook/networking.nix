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

  networking.computerName = "macbook";
  networking.hostName = "macbook";
  networking.localHostName = "macbook";
}
