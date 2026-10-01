# NixOS/desktop.nix - Desktop, power management, and remote-access services.
# Both GNOME and KDE Plasma ship an archive manager (File Roller, Ark) and a
# terminal-opening context-menu action, so switching desktops loses neither.
# Power management lives here because desktop, remote access, and power posture
# all use the NixOS services layer.
{ lib, pkgs, ... }:

let
  # Bundle scripts into the nix store so activation reads them without
  # NUCLEUS_REPO_ROOT, like activation.nix.
  activationBundle = pkgs.callPackage ../../modules/lib/script-tree.nix { };
in
{
  # vkms gives a software-only display when no monitor is attached, mirroring the
  # macOS BetterDisplay HeadlessDisplay.  It is a kernel-native virtual DRM
  # driver, adding a display alongside any real GPU rather than replacing it.
  boot.kernelModules = [ "vkms" ];

  # OBS comes from the cross-host registry (core.nix "obs-studio"), so only the
  # virtual-camera backend is pulled in here.  package = null avoids a second
  # wrapped install; enableVirtualCamera wires v4l2loopback and polkit on its own.
  programs.obs-studio.enable = true;
  programs.obs-studio.package = null;
  programs.obs-studio.enableVirtualCamera = true;

  services.xserver = {
    enable = true;
  };

  services.desktopManager.gnome.enable = true;
  services.desktopManager.plasma6.enable = true;

  # One display manager for both sessions.
  services.displayManager.gdm.enable = true;

  # seahorse (GNOME) and ksshaskpass (Plasma) both set programs.ssh.askPassword;
  # pinning one implementation keeps full toplevel evaluation from failing on
  # conflicting values while both desktops are enabled.
  programs.ssh.askPassword = lib.mkForce "${pkgs.kdePackages.ksshaskpass}/bin/ksshaskpass";

  environment.systemPackages =
    (with pkgs; [
      file-roller
      kdePackages.ark
      p7zip

      # Terminal emulators for the "Open in Terminal" context menu action.
      gnome-terminal # default terminal for GNOME "Open in Terminal"
      kdePackages.konsole # default terminal for KDE "Open in Terminal"

      # Dynamic governor tuning by AC/battery state beats static CPU caps.
      auto-cpufreq

      # Outbound remote desktop.  Parsec covers low-latency GPU sessions;
      # Chrome Remote Desktop has no nixpkgs package, so MANUAL.md covers the
      # Debian install and the one-time browser authorization for inbound access
      # (X11 logins only).
      parsec-bin

      easyeffects # graphical PipeWire audio processing GUI
      gimp
      pass
      qtpass

      # WHY: zenity draws the modal dialog the "strip metadata" Nautilus entry
      # uses to report inputs it could not process.
      zenity
    ])
    ++ lib.optionals (pkgs.gnome ? nautilus-open-terminal) [
      pkgs.gnome.nautilus-open-terminal # adds "Open in Terminal" to Files context menu when available
    ];

  # GNOME core apps.  NTFS mount policy lives in filesystems.nix.
  services.gnome.core-apps.enable = true;

  # auto-cpufreq is the managed power optimizer daemon.  GNOME may enable
  # power-profiles-daemon by default, and both would fight over CPU governor
  # policy, so power-profiles-daemon stays off.
  services.auto-cpufreq.enable = true;
  services.power-profiles-daemon.enable = false;

  # Governor profiles mirroring macOS lowpowermode: powersave, prefer-power EPP
  # and no turbo on battery; performance, prefer-performance EPP and turbo auto on
  # AC.
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

  # Charge cap: hold the pack at 80 % and resume at 75 % where the battery
  # exposes the standard power_supply charge-control attributes.  Hardware
  # without the attributes is reported rather than failed, so the switch still
  # succeeds there.  macOS converges the same ceiling through the `battery` CLI.
  system.activationScripts.nixos-configure-charge-limit.text = lib.mkAfter ''
    "${activationBundle}/src/platforms/NixOS/scripts/nixos-configure-charge-limit.sh" \
      "/sys/class/power_supply"
  '';

  # Keep the machine awake with the lid closed on every power source, so
  # long-running agents and remote-desktop sessions survive a closed panel;
  # linux.nix already disables idle sleep on AC and battery.
  services.logind.settings.Login = {
    HandleLidSwitch = "ignore";
    HandleLidSwitchDocked = "ignore";
    HandleLidSwitchExternalPower = "ignore";
  };

  # TCP keepalive parity with macOS pmset tcpkeepalive=1, so SSH tunnels and
  # remote-desktop connections survive idle periods: first probe after 60 s, then
  # every 10 s, dropped after 6 consecutive failures.
  boot.kernel.sysctl = {
    "net.ipv4.tcp_keepalive_intvl" = 10;
    "net.ipv4.tcp_keepalive_probes" = 6;
    "net.ipv4.tcp_keepalive_time" = 60;
  };

  # xrdp serves RDP to any client.  defaultWindowManager starts a GNOME session per
  # connection, each with its own isolated X11 session, which avoids input
  # conflicts; openFirewall opens TCP 3389, blocked by the default deny policy
  # otherwise.
  services.xrdp = {
    defaultWindowManager = "${pkgs.gnome-session}/bin/gnome-session";
    enable = true;
    openFirewall = true;
  };

  # physlock locks the keyboard at the driver layer for cleaning: the console
  # switches to a blank text screen and the password unlocks it.
  services.physlock = {
    enable = true;
    allowAnyUser = true;
  };

  # Steam: hardware.graphics.enable32Bit brings the 32-bit Mesa/Vulkan drivers its
  # game runtime needs, and programs.steam.enable wires udev rules, runtime
  # libraries, and the binary.  No preview channel exists as a module option, so
  # this tracks stable.
  hardware.graphics.enable32Bit = true;
  programs.steam.enable = true;

  # Registry-driven GUI app auto-start: converges every app to its declared
  # XDG-autostart state, neutralizing any app-shipped .desktop (e.g.
  # steam.desktop) so only our mechanism remains.
  system.activationScripts.nixos-configure-app-autostart.text = lib.mkAfter ''
    "${activationBundle}/src/hosts/NixOS/scripts/nixos-configure-app-autostart.sh"
  '';

  # Registry-driven menu-bar and tray icon convergence, mirroring the macOS
  # mechanism.  Most entries are omitted on NixOS, so this no-ops by default.
  system.activationScripts.nixos-configure-menu-bar.text = lib.mkAfter ''
    "${activationBundle}/src/hosts/NixOS/scripts/nixos-configure-menu-bar.sh"
  '';

  # EasyEffects: PipeWire audio processing GUI.  Add a Limiter or Compressor under
  # Effects > Output; preset vaults such as Digitalone1/EasyEffects-Presets clone
  # into ~/.local/share/easyeffects/output/.
}
