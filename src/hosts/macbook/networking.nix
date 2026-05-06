# macbook/networking.nix — Network identity and firewall policy for the MacBook.
#
# WHY postActivation.text, not a custom script name:
#   nix-darwin (rev 8c62fba) assembles only a hardcoded fixed list of named
#   scripts into the activate binary; custom names are silently ignored.
#   postActivation is the correct extension point for scripts that must run
#   after openssh.  lib.mkBefore prepends before the HM activation call.
{ lib, ... }:
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
  # enableScreenSharing (postActivation fragment)
  # Enable macOS Screen Sharing (VNC/ARD protocol) as the remote-desktop server
  # for this host.  macOS does not ship a native RDP server; Screen Sharing is
  # the platform equivalent and is accessible from Microsoft Remote Desktop
  # clients (which support connecting to Macs) as well as any VNC client.
  # blockAllIncoming = false in the firewall config already permits the inbound
  # VNC port (5900); no additional firewall rule is needed.
  #
  # nix-darwin does not expose a services.screensharing option in this version;
  # the LaunchDaemon plist is already installed by macOS and just needs its
  # Disabled override cleared.
  #
  # launchctl load -w writes to the override database.  When the daemon is
  # already loaded, launchctl prints "Service already loaded" to stderr and may
  # return non-zero — this is expected steady-state behaviour, not an error.
  # Error suppression justification (all three conditions met):
  #   (1) Expected and benign: the daemon being already loaded is normal
  #       steady-state on an already-configured machine.
  #   (2) WHY comment: see above.
  #   (3) Checked afterward: launchctl list verifies the daemon is present in
  #       the system service table so a genuine load failure (e.g. missing
  #       plist) is still caught.
  # ---------------------------------------------------------------------------
  system.activationScripts.postActivation.text = lib.mkBefore ''
    # ---- enableScreenSharing ---------------------------------------------------
    /bin/launchctl load -w /System/Library/LaunchDaemons/com.apple.screensharing.plist 2>/dev/null || true
    if ! /bin/launchctl list com.apple.screensharing > /dev/null 2>&1; then
      echo "nucleus: Screen Sharing daemon not listed after load; remote desktop may not be active." >&2
    fi
  '';

  networking.computerName = "macbook";
  networking.hostName = "macbook";
  networking.localHostName = "macbook";
}
