# NixOS/desktop.nix — Desktop, power management, and remote-access services.
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
{ lib, pkgs, ... }: {
  # Load the virtual KMS (vkms) kernel module to provide a software-only
  # display device when no physical monitor is connected.  This mirrors the
  # BetterDisplay HeadlessDisplay virtual screen on macOS: remote-desktop
  # clients (Parsec in particular) and the display manager can use the virtual
  # framebuffer when the lid is closed or no monitor is attached.
  # vkms is a kernel-native virtual DRM/KMS driver; it does not replace GPU
  # drivers — it adds a virtual display alongside any real hardware.
  # Sources:
  # https://mynixos.com/nixpkgs/option/boot.kernelModules
  # https://docs.kernel.org/gpu/vkms.html
  boot.kernelModules = [ "vkms" ];

  # Enable X11 server and desktop managers.
  # Source: https://mynixos.com/nixpkgs/option/services.xserver.enable
  services.xserver = {
    enable = true;
  };

  # Enable GNOME desktop environment with File Roller archive manager.
  # Source: https://mynixos.com/nixpkgs/option/services.desktopManager.gnome.enable
  services.desktopManager.gnome.enable = true;

  # Enable KDE Plasma 6 desktop environment with Ark archive manager.
  # Source: https://mynixos.com/nixpkgs/option/services.desktopManager.plasma6.enable
  services.desktopManager.plasma6.enable = true;

  # Use a display manager that can launch both GNOME and KDE sessions.
  # Source: https://mynixos.com/nixpkgs/option/services.displayManager.gdm.enable
  services.displayManager.gdm.enable = true;

  # GNOME (seahorse) and Plasma (ksshaskpass) both define programs.ssh.askPassword.
  # Pin one deterministic askpass implementation so full toplevel evaluation
  # does not fail with conflicting option values when both desktops are enabled.
  # Source: https://mynixos.com/nixpkgs/option/programs.ssh.askPassword
  programs.ssh.askPassword = lib.mkForce "${pkgs.kdePackages.ksshaskpass}/bin/ksshaskpass";

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
      gnome-terminal # default terminal for GNOME "Open in Terminal"
      kdePackages.konsole # default terminal for KDE "Open in Terminal"

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
      easyeffects # graphical PipeWire audio processing GUI
      gimp
      krita
      libreoffice
      pass
      picard
      qtpass
      zoom-us
    ])
    ++ lib.optionals (pkgs.gnome ? nautilus-open-terminal) [
      pkgs.gnome.nautilus-open-terminal # adds "Open in Terminal" to Files context menu when available
    ];

  # Enable GNOME services if GNOME is enabled above.
  # Source: https://mynixos.com/nixpkgs/option/services.gnome.core-apps.enable
  #
  # NTFS read/write for removable drives is handled by GNOME's built-in
  # udisks2 and GVFS, using ntfs-3g (FUSE) — active by default via
  # `boot.supportedFilesystems = [ "ntfs" ]` from the nixpkgs base profile.
  # The in-kernel ntfs3 driver (built-in since Linux 5.15) is NOT used:
  # partitions left "dirty" by Windows fast-startup refuse mount without
  # `force`, and making udisks2 prefer ntfs3 requires a udev rule that Arch
  # Wiki recommends against ("can confuse some 3rd party tools").
  # ntfs-3g handles dirty volumes gracefully with no compatibility issues.
  # https://wiki.archlinux.org/title/NTFS#unknown_filesystem_type_'ntfs'
  services.gnome.core-apps.enable = true;

  # Run auto-cpufreq as the managed NixOS power optimizer daemon.
  # Source: NixOS auto-cpufreq service option.
  # https://mynixos.com/nixpkgs/option/services.auto-cpufreq.enable
  services.auto-cpufreq.enable = true;

  # GNOME may enable power-profiles-daemon by default, but that service
  # conflicts with auto-cpufreq (both attempt to control CPU governor policy).
  # Keep auto-cpufreq as the single source of truth for power tuning.
  # Source: NixOS power-profiles-daemon option.
  # https://mynixos.com/nixpkgs/option/services.power-profiles-daemon.enable
  services.power-profiles-daemon.enable = false;

  # CPU governor profiles mirror macOS lowpowermode parity:
  #   battery (lowpowermode=1 equivalent): powersave governor, prefer-power EPP,
  #     turbo disabled — reduces heat and extends runtime when on battery.
  #   charger (lowpowermode=0 equivalent): performance governor, prefer-performance
  #     EPP, turbo auto — allows full CPU throughput when on AC power.
  # Source: https://github.com/AdnanHodzic/auto-cpufreq#configuration-file-options
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

  # logind lid-close behaviour: keep the machine awake with the lid closed on
  # every power source so long-running AI agents and remote-desktop sessions do
  # not die just because the panel was shut.  linux.nix already disables idle
  # sleep on both AC and battery; lid handling must match that always-on
  # posture instead of reintroducing a suspend path only for the lid switch.
  # Source: https://www.freedesktop.org/software/systemd/man/logind.conf.html
  services.logind.settings.Login = {
    HandleLidSwitch = "ignore";
    HandleLidSwitchDocked = "ignore";
    HandleLidSwitchExternalPower = "ignore";
  };

  # TCP keepalive parity: maintain persistent SSH tunnels and remote-desktop
  # connections through idle periods.  Mirrors macOS pmset tcpkeepalive=1.
  #   tcp_keepalive_time:   60 s before the first keepalive probe is sent.
  #   tcp_keepalive_intvl:  10 s between subsequent probes.
  #   tcp_keepalive_probes:  6 consecutive failures before the connection is dropped.
  # Source: https://www.kernel.org/doc/html/latest/networking/ip-sysctl.html
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
  # Source: NixOS XRDP defaultWindowManager option.
  # https://mynixos.com/nixpkgs/option/services.xrdp.defaultWindowManager
  services.xrdp = {
    defaultWindowManager = "${pkgs.gnome-session}/bin/gnome-session";
    enable = true;
    openFirewall = true;
  };

  # physlock: lock the keyboard at the driver layer for cleaning.
  # The console switches to a blank text screen; type your password to unlock.
  # Source: https://mynixos.com/nixpkgs/option/services.physlock.enable
  services.physlock = {
    enable = true;
    allowAnyUser = true;
  };

  # Steam game distribution platform.
  # hardware.graphics.enable32Bit provides the 32-bit Mesa/Vulkan drivers
  # required by Steam's 32-bit game runtime.  programs.steam.enable wires up
  # system integration: udev rules, required runtime libraries, and the Steam
  # binary itself.
  # Channel note: no Steam beta/preview channel is exposed as a NixOS module
  # option; programs.steam always tracks the latest stable release.
  # Cross-platform parity: macOS uses the Homebrew steam cask; Windows uses
  # Valve.Steam in system-packages.dsc.yml.
  # Sources:
  # https://nixos.wiki/wiki/Steam
  # https://mynixos.com/nixpkgs/option/programs.steam.enable
  hardware.graphics.enable32Bit = true;
  programs.steam.enable = true;

  # EasyEffects: graphical PipeWire audio processing GUI with plugin-based
  # limiter, compressor, equalizer, and other DSP effects.
  # Usage: open the EasyEffects GUI, navigate to Effects > Output > Add Effect,
  # and select Limiter or Compressor. Community preset vaults (like
  # Digitalone1/EasyEffects-Presets) can be cloned into
  # ~/.local/share/easyeffects/output/.
}
