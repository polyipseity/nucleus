# nixos/desktop.nix — Multi-desktop archiving and file management ecosystem.
#
# Enables both GNOME and KDE Plasma desktop managers with their respective
# archive managers (File Roller and Ark) so users can switch between
# desktop environments without losing GUI archiving capability.
# The underlying p7zip engine is available system-wide.
# Cross-platform context menu parity: both desktops include terminal opening
# actions in file manager context menus (nautilus-open-terminal, dolphin).
{ lib, pkgs, ... }:
{
  # Enable X11 server and desktop managers.
  services.xserver = {
    enable = true;

    # Enable GNOME desktop environment with File Roller archive manager.
    desktopManager.gnome.enable = true;

    # Enable KDE Plasma 6 desktop environment with Ark archive manager.
    desktopManager.plasma6.enable = true;

    # Use a display manager that can launch both GNOME and KDE sessions.
    displayManager.gdm.enable = true;
  };

  # Install graphical archive managers per desktop environment.
  environment.systemPackages = with pkgs; [
    # GNOME archive manager and terminal extension for Files (Nautilus).
    gnome.file-roller
    gnome.nautilus-open-terminal  # adds "Open in Terminal" to Files context menu

    # KDE archive manager with built-in terminal opening support.
    kdePackages.ark

    # Ensure the 7z engine is available globally for both GUI tools
    # (though p7zip is also declared in modules/core.nix, re-declare here
    # for explicit system-level availability in case core is not applied).
    p7zip

    # Terminal emulators for "Open in Terminal" context menu actions.
    gnome.gnome-terminal  # default terminal for GNOME "Open in Terminal"
    kdePackages.konsole   # default terminal for KDE "Open in Terminal"

    # Battery efficiency daemon: dynamic governor tuning based on AC/battery
    # state gives better laptop efficiency without hard-coding static CPU caps.
    auto-cpufreq
  ];

  # Enable GNOME services if GNOME is enabled above.
  services.gnome.core-utilities.enable = true;

  # Run auto-cpufreq as the managed NixOS power optimizer daemon.
  services.auto-cpufreq.enable = true;
}
