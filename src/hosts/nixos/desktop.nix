# nixos/desktop.nix — Desktop, power management, and remote-access services.
#
# Enables both GNOME and KDE Plasma desktop managers with their respective
# archive managers (File Roller and Ark) so users can switch between
# desktop environments without losing GUI archiving capability.
# The underlying p7zip engine is available system-wide.
# Cross-platform context menu parity: both desktops include terminal opening
# actions in file manager context menus (nautilus-open-terminal, dolphin).
# Power management is declared here alongside the desktop services because
# all three concerns (desktop environment, remote access, power posture) share
# the same NixOS services layer.
{ lib, pkgs, ... }:
{
  # Load the virtual KMS (vkms) kernel module to provide a software-only
  # display device when no physical monitor is connected.  This mirrors the
  # BetterDisplay HeadlessDisplay virtual screen on macOS: remote-desktop
  # clients (Parsec in particular) and the display manager can use the virtual
  # framebuffer when the lid is closed or no monitor is attached.
  # vkms is a kernel-native virtual DRM/KMS driver; it does not replace GPU
  # drivers — it adds a virtual display alongside any real hardware.
  boot.kernelModules = [ "vkms" ];

  # Enable X11 server and desktop managers.
  services.xserver = {
    enable = true;
  };

  # Enable GNOME desktop environment with File Roller archive manager.
  services.desktopManager.gnome.enable = true;

  # Enable KDE Plasma 6 desktop environment with Ark archive manager.
  services.desktopManager.plasma6.enable = true;

  # Use a display manager that can launch both GNOME and KDE sessions.
  services.displayManager.gdm.enable = true;

  # Install graphical archive managers per desktop environment.
  environment.systemPackages =
    (with pkgs; [
    # GNOME archive manager.
    file-roller

    # KDE archive manager with built-in terminal opening support.
    kdePackages.ark

    # Ensure the 7z engine is available globally for both GUI tools
    # (though p7zip is also declared in modules/core.nix, re-declare here
    # for explicit system-level availability in case core is not applied).
    p7zip

    # Terminal emulators for "Open in Terminal" context menu actions.
    gnome-terminal  # default terminal for GNOME "Open in Terminal"
    kdePackages.konsole   # default terminal for KDE "Open in Terminal"

    # Battery efficiency daemon: dynamic governor tuning based on AC/battery
    # state gives better laptop efficiency without hard-coding static CPU caps.
    auto-cpufreq

    # Remote-desktop clients for outbound access from this host.
    # Parsec is used for low-latency GPU-accelerated remote gaming/work sessions.
    # Chrome Remote Desktop is not available as a nixpkgs package; see MANUAL.md
    # for the one-time browser-extension setup required for inbound CRD access.
    parsec-bin

    # Productivity and creative applications.
    # GIMP and Krita: raster and digital painting editors.
    # LibreOffice: office suite.
    # Blender: 3D modelling, animation, and rendering.
    # Zoom: video conferencing.
    # pass: Unix password manager (compatible with gopass on Windows).
    # qtpass: Qt GUI frontend for pass/gopass.
    blender
    gimp
    krita
    libreoffice
    pass
    qtpass
    zoom-us
    ])
    ++ lib.optionals (pkgs.gnome ? nautilus-open-terminal) [
      pkgs.gnome.nautilus-open-terminal # adds "Open in Terminal" to Files context menu when available
    ];

  # Enable GNOME services if GNOME is enabled above.
  services.gnome.core-apps.enable = true;

  # Run auto-cpufreq as the managed NixOS power optimizer daemon.
  services.auto-cpufreq.enable = true;

  # GNOME may enable power-profiles-daemon by default, but that service
  # conflicts with auto-cpufreq (both attempt to control CPU governor policy).
  # Keep auto-cpufreq as the single source of truth for power tuning.
  services.power-profiles-daemon.enable = false;

  # CPU governor profiles mirror macOS lowpowermode parity:
  #   battery (lowpowermode=1 equivalent): powersave governor, prefer-power EPP,
  #     turbo disabled — reduces heat and extends runtime when on battery.
  #   charger (lowpowermode=0 equivalent): performance governor, prefer-performance
  #     EPP, turbo auto — allows full CPU throughput when on AC power.
  services.auto-cpufreq.settings = {
    battery = {
      energy_performance_preference = "power";
      governor = "powersave";
      turbo = "never";
    };
    charger = {
      energy_performance_preference = "performance";
      governor = "performance";
      turbo = "auto";
    };
  };

  # logind lid-close behaviour: keep the machine awake on external power with
  # lid closed so remote-desktop sessions are not disconnected when docked or
  # used in clamshell mode.  Default (suspend) is preserved on battery because
  # battery-powered clamshell is not a remote-access scenario.
  services.logind.settings.Login = {
    HandleLidSwitchExternalPower = "ignore";
  };

  # TCP keepalive parity: maintain persistent SSH tunnels and remote-desktop
  # connections through idle periods.  Mirrors macOS pmset tcpkeepalive=1.
  #   tcp_keepalive_time:   60 s before the first keepalive probe is sent.
  #   tcp_keepalive_intvl:  10 s between subsequent probes.
  #   tcp_keepalive_probes:  6 consecutive failures before the connection is dropped.
  boot.kernel.sysctl = {
    "net.ipv4.tcp_keepalive_intvl" = 10;
    "net.ipv4.tcp_keepalive_probes" = 6;
    "net.ipv4.tcp_keepalive_time" = 60;
  };

  # xrdp provides a standard RDP (Remote Desktop Protocol) server so this host
  # can be reached from any RDP client (Windows built-in Remote Desktop,
  # Microsoft Remote Desktop for macOS, Remmina, etc.).
  # defaultWindowManager starts a GNOME session per xrdp connection; each
  # connection gets its own isolated X11 session rather than sharing the console
  # session, which avoids input conflicts when multiple remote sessions are
  # active simultaneously.
  # openFirewall = true opens TCP 3389 in the NixOS firewall automatically;
  # without this the RDP port would be blocked by the default deny policy.
  services.xrdp = {
    defaultWindowManager = "${pkgs.gnome-session}/bin/gnome-session";
    enable = true;
    openFirewall = true;
  };
}
