# MacBook/networking.nix - network identity and firewall policy.
# ref: activation.nix - nix-darwin postActivation hook constraint
{ lib, pkgs, ... }:
let
  activationBundle = pkgs.callPackage ../../modules/lib/script-tree.nix { };
in
{
  # Application-level firewall: block unsigned inbound connections, allow
  # code-signed binaries.
  networking.applicationFirewall = {
    allowSigned = true; # allow signed apps to accept inbound connections
    blockAllIncoming = false;
    # per-app blocking is sufficient; a blanket block
    # would break screen sharing and remote desktop
    enable = true;
    enableStealthMode = false;
    # stealth mode hides the host from network scans;
    # disabled to keep remote-desktop discovery working
  };

  # Screen Sharing is the remote-desktop server: macOS has no native RDP, and
  # the firewall block above already permits the inbound VNC port. This nixpkgs
  # version has no services.screensharing option, so the macOS LaunchDaemon
  # plist just needs its Disabled override cleared.
  # launchctl load -w reports "Service already loaded" and may exit non-zero in
  # that steady state; launchctl list afterwards confirms the daemon is
  # registered.
  system.activationScripts.postActivation.text = lib.mkBefore ''"${activationBundle}/src/hosts/MacBook/scripts/macos-setup-networking.sh"'';

  # Titlecase hostname matches the machine identity and keeps local discovery
  # working on macOS.
  networking.computerName = "MacBook";
  networking.hostName = "MacBook";
  networking.localHostName = "MacBook";
}
