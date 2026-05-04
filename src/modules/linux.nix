# modules/linux.nix — Linux-only Home Manager desktop/session parity settings.
# Mirrors core UX/security intent from macOS defaults where GNOME equivalents
# exist (clock, lock behavior, touchpad/keyboard ergonomics, privacy, and power).
{ config, lib, pkgs, ... }:
lib.mkIf pkgs.stdenv.isLinux {
  # Home Manager exposes GNOME settings via `dconf.*` (not `programs.dconf`).
  # Enabling this keeps `dconf.settings` declarative and idempotent.
  dconf.enable = true;

  dconf.settings = {
    # Input source baseline parity:
    # - Keep US layout as default (matches macOS login/default source intent).
    # - Leave additional IME engines to user-installed ibus engines.
    "org/gnome/desktop/input-sources" = {
      sources = [
        (lib.hm.gvariant.mkTuple [ "xkb" "us" ])
      ];
    };

    # macOS global UX parity: 24h clock, visible date/weekday/seconds,
    # reduced window animation, always-visible battery percentage.
    "org/gnome/desktop/interface" = {
      clock-format = "24h";
      clock-show-date = true;
      clock-show-seconds = true;
      clock-show-weekday = true;
      cursor-size = 32;
      enable-animations = false;
      show-battery-percentage = true;
    };

    # Keep lock screen available and enforce immediate password requirement.
    "org/gnome/desktop/lockdown" = {
      disable-lock-screen = false;
    };

    # Fast key repeat parity with aggressive macOS key-repeat defaults.
    "org/gnome/desktop/peripherals/keyboard" = {
      delay = lib.hm.gvariant.mkUint32 250;
      repeat = true;
      repeat-interval = lib.hm.gvariant.mkUint32 20;
    };

    # Trackpad ergonomics mirroring macOS tap-to-click + natural scrolling.
    "org/gnome/desktop/peripherals/touchpad" = {
      natural-scroll = true;
      speed = 1.0;
      tap-to-click = true;
    };

    # Finder/Safari/Spotlight privacy intent parity:
    # - Disable external search providers.
    # - Avoid recent-file persistence.
    # - Auto-clean temporary and trash content.
    "org/gnome/desktop/privacy" = {
      old-files-age = lib.hm.gvariant.mkUint32 30;
      remember-recent-files = false;
      remove-old-temp-files = true;
      remove-old-trash-files = true;
    };

    # Spotlight parity: no web/external lookups from desktop search.
    "org/gnome/desktop/search-providers" = {
      disable-external = true;
    };

    # Security invariant parity: lock immediately once session idles.
    "org/gnome/desktop/screensaver" = {
      lock-delay = lib.hm.gvariant.mkUint32 0;
      lock-enabled = true;
    };

    # Aggressive display idle (1 minute) to mirror macOS display sleep policy.
    "org/gnome/desktop/session" = {
      idle-delay = lib.hm.gvariant.mkUint32 60;
    };

    # Terminal focus-follow-mouse parity from macOS Terminal preferences.
    "org/gnome/desktop/wm/preferences" = {
      focus-mode = "sloppy";
    };

    # Screenshot defaults parity: PNG to Desktop.
    "org/gnome/gnome-screenshot" = {
      auto-save-directory = "file://${config.home.homeDirectory}/Desktop";
      default-file-type = "png";
    };

    # Window-management parity: edge tiling and per-display workspace behavior.
    "org/gnome/mutter" = {
      edge-tiling = true;
      workspaces-only-on-primary = false;
    };

    # Finder-ish file-browser defaults where GNOME has equivalents.
    "org/gnome/nautilus/preferences" = {
      default-folder-viewer = "list-view";
      show-delete-permanently = true;
      show-image-thumbnails = "always";
    };

    # Night Shift parity (18:00 → 06:00, warm tone).
    "org/gnome/settings-daemon/plugins/color" = {
      night-light-enabled = true;
      night-light-schedule-automatic = false;
      night-light-schedule-from = 18.0;
      night-light-schedule-to = 6.0;
      night-light-temperature = lib.hm.gvariant.mkUint32 3700;
    };

    # AC vs battery behavior parity with macOS remote-access-first profile.
    "org/gnome/settings-daemon/plugins/power" = {
      sleep-inactive-ac-timeout = lib.hm.gvariant.mkUint32 0;
      sleep-inactive-ac-type = "nothing";
      sleep-inactive-battery-timeout = lib.hm.gvariant.mkUint32 1800;
      sleep-inactive-battery-type = "suspend";
    };
  };
}
