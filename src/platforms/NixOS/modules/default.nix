# Linux-only desktop/session parity settings (GNOME) and systemd user units.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  sccacheGc = pkgs.writeNucleusShellApplication {
    name = "sccache-gc";
    runtimeInputs = [ pkgs.sccache ];
    scriptName = "src/scripts/services/sccache-gc";
  };

  activationBundle = pkgs.callPackage ../../../modules/lib/script-tree.nix { };
in
lib.mkIf pkgs.stdenv.hostPlatform.isLinux {
  # Home Manager exposes GNOME settings via `dconf.*` (not `programs.dconf`), which
  # keeps `dconf.settings` declarative and idempotent.
  dconf.enable = true;

  dconf.settings = {
    # US layout as the default source; extra IME engines come from ibus.
    "org/gnome/desktop/input-sources" = {
      sources = [
        (lib.hm.gvariant.mkTuple [
          "xkb"
          "us"
        ])
      ];
    };

    # macOS UX parity: 24h clock, visible date, weekday and seconds, no window
    # animation, always-visible battery percentage.
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

    # Fast key repeat, matching the macOS defaults.
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

    # Lower persistent UI and history noise, while keeping file and navigation
    # surfaces discoverable.
    "org/gnome/desktop/privacy" = {
      old-files-age = lib.hm.gvariant.mkUint32 30;
      remember-recent-files = false;
      remove-old-temp-files = true;
      remove-old-trash-files = true;
    };

    # Keep external search providers visible so GNOME search surfaces all
    # available information sources.
    "org/gnome/desktop/search-providers" = {
      disable-external = false;
    };

    # GTK file chooser: filename entry, hidden files, and key columns visible.
    "org/gtk/settings/file-chooser" = {
      location-mode = "filename-entry";
      show-hidden = true;
      show-size-column = true;
      show-type-column = true;
    };

    # Lock the session as soon as it idles.
    "org/gnome/desktop/screensaver" = {
      lock-delay = lib.hm.gvariant.mkUint32 0;
      lock-enabled = true;
    };

    # Display idles after one minute, matching the macOS display sleep policy.
    "org/gnome/desktop/session" = {
      idle-delay = lib.hm.gvariant.mkUint32 60;
    };

    # Follow-mouse focus, as in macOS Terminal preferences.
    "org/gnome/desktop/wm/preferences" = {
      focus-mode = "sloppy";
    };

    # Screenshots save as PNG on the Desktop.
    "org/gnome/gnome-screenshot" = {
      auto-save-directory = "file://${config.home.homeDirectory}/Desktop";
      default-file-type = "png";
    };

    # Window management: edge tiling, workspaces on every display.
    "org/gnome/mutter" = {
      edge-tiling = true;
      workspaces-only-on-primary = false;
    };

    # Nautilus defaults: list view, permanent delete, full path titles, hidden files,
    # thumbnails.
    "org/gnome/nautilus/preferences" = {
      default-folder-viewer = "list-view";
      show-directory-item-counts = "always";
      show-delete-permanently = true;
      show-full-path-titles = true;
      show-hidden-files = true;
      show-image-thumbnails = "always";
    };

    # User extensions stay enabled so shell capabilities are not hidden by default.
    "org/gnome/shell" = {
      disable-user-extensions = false;
    };

    # Night Shift, 18:00 to 06:00 at a warm tone.
    "org/gnome/settings-daemon/plugins/color" = {
      night-light-enabled = true;
      night-light-schedule-automatic = false;
      night-light-schedule-from = 18.0;
      night-light-schedule-to = 6.0;
      night-light-temperature = lib.hm.gvariant.mkUint32 3700;
    };

    # Battery sleep is off (type "nothing", timeout 0) so remote-desktop sessions
    # (xrdp, Chrome Remote Desktop, Parsec) survive on battery; sleeping would
    # silently disconnect active sessions and block inbound connections.  AC and
    # battery postures match so behaviour does not change on unplug.
    "org/gnome/settings-daemon/plugins/power" = {
      sleep-inactive-ac-timeout = lib.hm.gvariant.mkUint32 0;
      sleep-inactive-ac-type = "nothing";
      sleep-inactive-battery-timeout = lib.hm.gvariant.mkUint32 0;
      sleep-inactive-battery-type = "nothing";
    };
  };

  home.activation = {
    # build-nix-index: start a background nix-index build on first provision so
    # the database is ready before the daily systemd timer fires, and later
    # refreshes come from that timer.  A full build takes minutes, so it is
    # backgrounded, and stdout is dropped because nix-index prints per-channel
    # progress that would swamp the activation log.  A failed build is benign:
    # pay-respects falls back to suggesting nothing and the timer retries.
    build-nix-index = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      "${activationBundle}/src/scripts/packages/update-nix-index.sh" \
        "${pkgs.nix-index}/bin/nix-index" \
        ""
    '';

    # ensure-dev-directory: create ~/dev when absent, mirroring macOS, since
    # VS Code workspace trust and the editor tooling expect it on every host.
    ensure-dev-directory = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      mkdir -p "$HOME/dev"
    '';

  };

  # nix-index-update service and timer, keeping the file database current so
  # pay-respects can suggest `nix profile install` for an unknown command.  Daily
  # at 12:00 with Persistent=true, so the database stays fresh on machines that
  # sit off overnight; the first-provision build covers the initial case.
  systemd.user.services."nix-index-update" = {
    Unit = {
      Description = "Rebuild nix-index file database";
      # After network.target so channel index fetches succeed.
      After = "network.target";
    };
    Service = {
      Type = "oneshot";
      ExecStart = "${pkgs.nix-index}/bin/nix-index";
    };
  };

  systemd.user.timers."nix-index-update" = {
    Unit = {
      Description = "Daily nix-index database refresh";
    };
    Timer = {
      # Daily at 12:00.  Persistent=true catches up on next login, which bounds
      # cache growth on intermittently used machines.
      OnCalendar = "12:00:00";
      Persistent = true;
      Unit = "nix-index-update.service";
    };
    Install = {
      WantedBy = [ "timers.target" ];
    };
  };

  # Daily sccache cache clearing at 12:00, matching the macOS agent and the
  # Windows scheduled task.
  systemd.user.services."sccache-gc" = {
    Unit = {
      Description = "Daily sccache cache clearing";
    };
    Service = {
      Type = "oneshot";
      ExecStart = "${sccacheGc}/bin/nucleus-sccache-gc";
    };
  };

  systemd.user.timers."sccache-gc" = {
    Unit = {
      Description = "Daily sccache cache clearing timer";
    };
    Timer = {
      # Daily at 12:00.  Persistent=true catches up on next login, which bounds
      # cache growth on intermittently used machines.
      OnCalendar = "12:00:00";
      Persistent = true;
      Unit = "sccache-gc.service";
    };
    Install = {
      WantedBy = [ "timers.target" ];
    };
  };

  # VLC handles every audio format Picard claims in its desktop file.  Without
  # explicit overrides, installation order decides the handler, so double-clicking
  # an audio file opens Picard (a tagger) instead of the player.
  # Sources:
  # https://specifications.freedesktop.org/mime-apps-spec/1.0/
  # https://wiki.videolan.org/VLC_Features_Formats/
  xdg.mimeApps = {
    enable = true;
    defaultApplications = lib.genAttrs [
      "audio/aiff"
      "audio/flac"
      "audio/mp4"
      "audio/mpeg"
      "audio/ogg"
      "audio/x-ape"
      "audio/x-aiff"
      "audio/x-flac"
      "audio/x-ms-wma"
      "audio/x-musepack"
      "audio/x-opus+ogg"
      "audio/x-tta"
      "audio/x-vorbis+ogg"
      "audio/x-wav"
      "audio/x-wavpack"
    ] (_: [ "vlc.desktop" ]);
  };
}
