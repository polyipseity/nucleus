# Linux-only desktop/session parity settings (GNOME) and systemd user units.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  # Capture NUCLEUS_REPO_ROOT at eval time as fallback for activation contexts
  # where the env var may not be inherited (home-manager activation,
  # systemd services).
  repoRoot = builtins.getEnv "NUCLEUS_REPO_ROOT";

  # Wrapper that resolves the nucleus repo root at runtime so the systemd unit
  # works regardless of the checkout location. Uses eval-time fallback for
  # contexts where NUCLEUS_REPO_ROOT may not be inherited.
  gcWeekly = pkgs.writeShellScript "gc-weekly" (builtins.readFile ../scripts/services/gc-sweep.sh);

  sccacheGc = pkgs.writeShellScript "sccache-gc" (
    builtins.readFile ../scripts/services/sccache-gc.sh
  );

  activationBundle = pkgs.callPackage ./lib/activation-bundle.nix { };
in
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
        (lib.hm.gvariant.mkTuple [
          "xkb"
          "us"
        ])
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

    # Privacy/history defaults favor lower persistent UI/state noise while still
    # preserving explicit discoverability controls in file/navigation surfaces.
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

    # GTK file chooser visibility defaults: show hidden files and keep key
    # columns visible for richer file metadata in open/save dialogs.
    "org/gtk/settings/file-chooser" = {
      location-mode = "filename-entry";
      show-hidden = true;
      show-size-column = true;
      show-type-column = true;
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
      show-directory-item-counts = "always";
      show-delete-permanently = true;
      show-full-path-titles = true;
      show-hidden-files = true;
      show-image-thumbnails = "always";
    };

    # Keep user extensions enabled to avoid hiding shell capabilities by default.
    "org/gnome/shell" = {
      disable-user-extensions = false;
    };

    # Night Shift parity (18:00 → 06:00, warm tone).
    "org/gnome/settings-daemon/plugins/color" = {
      night-light-enabled = true;
      night-light-schedule-automatic = false;
      night-light-schedule-from = 18.0;
      night-light-schedule-to = 6.0;
      night-light-temperature = lib.hm.gvariant.mkUint32 3700;
    };

    # Battery suspend is disabled (type = "nothing", timeout = 0) so that
    # remote-desktop sessions (xrdp, Chrome Remote Desktop, Parsec) survive
    # when the machine is on battery.  Sleeping on battery would silently
    # disconnect active remote sessions and block new inbound connections.
    # Both AC and battery postures are set to "nothing" so behavior is
    # consistent regardless of power source — avoiding confusing disconnects
    # that only happen when the laptop is unplugged.
    "org/gnome/settings-daemon/plugins/power" = {
      sleep-inactive-ac-timeout = lib.hm.gvariant.mkUint32 0;
      sleep-inactive-ac-type = "nothing";
      sleep-inactive-battery-timeout = lib.hm.gvariant.mkUint32 0;
      sleep-inactive-battery-type = "nothing";
    };
  };

  home.activation = {
    # -----------------------------------------------------------------------
    # buildNixIndex
    # Starts a background nix-index build on first provision so the database
    # is available shortly after provisioning without waiting for the daily
    # systemd timer.  Subsequent refreshes are handled by the timer.
    #
    # The build is backgrounded to avoid blocking the activation chain; a full
    # nix-index build takes several minutes.  Output is suppressed because
    # nix-index emits verbose per-channel progress on stdout that would
    # pollute the activation log.  This suppression is intentional: (1) a
    # failed build is benign (pay-respects falls back to not suggesting
    # packages), (2) this comment explains why, and (3) the timer and any
    # subsequent provision run serve as implicit follow-up checks.
    # -----------------------------------------------------------------------
    buildNixIndex = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      "${activationBundle}/packages/update-nix-index.sh" \
        "${pkgs.nix-index}/bin/nix-index" \
        ""
    '';

    # -----------------------------------------------------------------------
    # provisionDevDirectory
    # Creates ~/dev when absent so NixOS mirrors the macOS
    # configureSystemHardening behaviour.  VS Code workspace trust and editor
    # tooling rely on the directory existing on all hosts.
    # -----------------------------------------------------------------------
    provisionDevDirectory = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      mkdir -p "$HOME/dev"
    '';

  };

  # --------------------------------------------------------------------------
  # nix-index-update systemd service and timer
  # Keeps the nix-index file database current so pay-respects can suggest
  # `nix profile install` commands when an unknown command is typed.
  #
  # The timer fires daily (12:00, Persistent=true) so the DB stays fresh even
  # after mid-week package installs on intermittently used machines.
  # buildNixIndex handles the
  # first-provision case so the DB is available before the timer first fires.
  # --------------------------------------------------------------------------
  systemd.user.services."nix-index-update" = {
    Unit = {
      Description = "Rebuild nix-index file database";
      # Defer until network is available so channel index fetches succeed.
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
      # Fire daily at 12:00 local time.  Persistent=true ensures the timer
      # catches up on the next login when the machine was off at the
      # scheduled time, preventing the DB from going stale on laptops that
      # are not powered on overnight every day.
      OnCalendar = "12:00:00";
      Persistent = true;
      Unit = "nix-index-update.service";
    };
    Install = {
      WantedBy = [ "timers.target" ];
    };
  };

  # --------------------------------------------------------------------------
  # Weekly garbage collection — runs on Sunday at noon to reclaim stale VM
  # artifacts, build outputs, and tool caches that accumulate across weeks.
  systemd.user.services."gc-weekly" = {
    Unit = {
      Description = "Weekly garbage collection (VM, build, cache artifacts)";
      After = [ "network-online.target" ];
      Wants = [ "network-online.target" ];
    };
    Service = {
      Type = "oneshot";
      ExecStart = "${gcWeekly}";
      Environment = "NUCLEUS_REPO_ROOT=${repoRoot}";
    };
  };

  systemd.user.timers."gc-weekly" = {
    Unit = {
      Description = "Weekly garbage collection timer";
    };
    Timer = {
      # Fire every Sunday at 12:00 local time. Persistent=true ensures the timer
      # catches up on the next login when the machine was off at the scheduled
      # time, preventing stale artifacts from accumulating indefinitely.
      OnCalendar = "Sun *-*-* 12:00:00";
      Persistent = true;
      Unit = "gc-weekly.service";
    };
    Install = {
      WantedBy = [ "timers.target" ];
    };
  };

  # --------------------------------------------------------------------------
  # Daily sccache cache clearing
  # Clears the sccache compilation cache every day at 12:00. Cross-host parity
  # with macOS launchd agent and Windows scheduled task.
  systemd.user.services."sccache-gc" = {
    Unit = {
      Description = "Daily sccache cache clearing";
    };
    Service = {
      Type = "oneshot";
      ExecStart = "${sccacheGc}";
    };
  };

  systemd.user.timers."sccache-gc" = {
    Unit = {
      Description = "Daily sccache cache clearing timer";
    };
    Timer = {
      # Fire daily at 12:00 local time. Persistent=true ensures the timer
      # catches up on the next login when the machine was off at the scheduled
      # time, preventing unbounded cache growth on intermittently used machines.
      OnCalendar = "12:00:00";
      Persistent = true;
      Unit = "sccache-gc.service";
    };
    Install = {
      WantedBy = [ "timers.target" ];
    };
  };

  # --------------------------------------------------------------------------
  # Audio MIME type defaults — keep VLC as the default handler for all audio
  # formats that MusicBrainz Picard claims in its desktop file.  Without
  # explicit overrides, installation order determines which application handles
  # double-clicks on audio files, which causes Picard (a tagger, not a player)
  # to open instead of VLC.
  # Sources:
  # https://specifications.freedesktop.org/mime-apps-spec/1.0/
  # https://wiki.videolan.org/VLC_Features_Formats/
  # --------------------------------------------------------------------------
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
