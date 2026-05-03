# modules/linux.nix — Linux-only Home Manager desktop/session parity settings.
# Mirrors core UX/security intent from macOS defaults where GNOME equivalents
# exist (clock, lock behavior, touchpad ergonomics, and power policy).
{ lib, pkgs, ... }:
lib.mkIf pkgs.stdenv.isLinux {
  programs.dconf.enable = true;

  dconf.settings = {
    # 24-hour clock + weekday + seconds, battery percentage, reduced UI motion.
    "org/gnome/desktop/interface" = {
      clock-format = "24h";
      clock-show-seconds = true;
      clock-show-weekday = true;
      cursor-size = 32;
      enable-animations = false;
      show-battery-percentage = true;
    };

    # Trackpad ergonomics mirroring macOS tap-to-click + natural scrolling.
    "org/gnome/desktop/peripherals/touchpad" = {
      natural-scroll = true;
      speed = 1.0;
      tap-to-click = true;
    };

    # Privacy parity: disable online/external search suggestions.
    "org/gnome/desktop/search-providers" = {
      disable-external = true;
    };

    # Security invariant parity: lock immediately once the session idles.
    "org/gnome/desktop/screensaver" = {
      lock-delay = lib.hm.gvariant.mkUint32 0;
      lock-enabled = true;
    };

    # Aggressive display idle (1 minute) to mirror macOS display sleep policy.
    "org/gnome/desktop/session" = {
      idle-delay = lib.hm.gvariant.mkUint32 60;
    };

    # AC vs battery behavior mirroring the "always available on power" model.
    "org/gnome/settings-daemon/plugins/power" = {
      sleep-inactive-ac-timeout = lib.hm.gvariant.mkUint32 0;
      sleep-inactive-ac-type = "nothing";
      sleep-inactive-battery-timeout = lib.hm.gvariant.mkUint32 1800;
      sleep-inactive-battery-type = "suspend";
    };
  };
}
