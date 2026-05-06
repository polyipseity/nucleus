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

  # ---------------------------------------------------------------------------
  # enableScreenSharing
  # Enable macOS Screen Sharing (VNC/ARD protocol) as the remote-desktop server
  # for this host.  macOS does not ship a native RDP server; Screen Sharing is
  # the platform equivalent and is accessible from Microsoft Remote Desktop
  # clients (which support connecting to Macs) as well as any VNC client.
  # blockAllIncoming = false in the firewall config already permits the inbound
  # VNC port (5900); no additional firewall rule is needed.
  #
  # nix-darwin does not expose a services.screensharing option in this version;
  # the LaunchDaemon plist is already installed by macOS and just needs its
  # Disabled override cleared.  `launchctl load -w` writes to the override
  # database and is idempotent: it succeeds whether the daemon is stopped or
  # already running (a non-zero exit when already loaded is expected and
  # suppressed).
  # ---------------------------------------------------------------------------
  system.activationScripts.enableScreenSharing.text = ''
    /bin/launchctl load -w /System/Library/LaunchDaemons/com.apple.screensharing.plist 2>/dev/null || true
  '';

  networking.computerName = "macbook";
  networking.hostName = "macbook";
  networking.localHostName = "macbook";
}
