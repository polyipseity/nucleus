# modules/linux.nix — Linux-only Home Manager desktop/session parity settings.
# Mirrors core UX/security intent from macOS defaults where GNOME equivalents
# exist (clock, lock behavior, touchpad/keyboard ergonomics, privacy, and power).
#
# Systemd user units managed by this module:
#   jellyfin-media-server.service — runs Jellyfin from the managed user profile
#     so the media library lives in the user's home directory without an extra
#     system account to reconcile across hosts.
#   nix-index-update.service — rebuilds the nix-index file database on demand.
#   nix-index-update.timer   — fires daily (00:00) with Persistent=true.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  # User-scoped Jellyfin launcher.
  # WHY user service: this repository already converges per-user media/storage
  # state through Home Manager on POSIX hosts, so keeping Jellyfin inside the
  # managed user session avoids an extra system account and keeps library paths
  # consistent with the cross-host cloud-drive layout.
  jellyfinMediaServer = pkgs.writeShellScript "jellyfin-media-server" ''
    set -eu

    config_dir="${config.home.homeDirectory}/.config/jellyfin"
    data_dir="${config.home.homeDirectory}/.local/share/jellyfin"
    cache_dir="${config.home.homeDirectory}/.cache/jellyfin"
    log_dir="${config.home.homeDirectory}/.local/state/jellyfin/log"

    mkdir -p "$config_dir" "$data_dir" "$cache_dir" "$log_dir"

    exec ${pkgs.jellyfin}/bin/jellyfin \
      --configdir "$config_dir" \
      --datadir "$data_dir" \
      --cachedir "$cache_dir" \
      --logdir "$log_dir"
  '';
in
lib.mkIf pkgs.stdenv.isLinux {
  assertions = [
    {
      assertion = config.nucleus.hostManualFile != null;
      message = "modules/linux.nix requires nucleus.hostManualFile to be set by the Linux host entrypoint (for example ./MANUAL.md in src/hosts/NixOS/default.nix).";
    }
  ];

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
      _db_file="$HOME/.cache/nix-index/files"
      if [ ! -f "$_db_file" ]; then
        ${pkgs.nix-index}/bin/nix-index >/dev/null 2>&1 &
        echo "linux: nix-index database build started in background; this may take a few minutes." >&2
      fi
    '';

    # -----------------------------------------------------------------------
    # provisionDevDirectory
    # Creates ~/dev when absent so NixOS mirrors the macOS
    # configureSystemHardening behaviour.  VS Code workspace trust and editor
    # tooling rely on the directory existing on all hosts.
    # -----------------------------------------------------------------------
    provisionDevDirectory = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      if [ ! -d "$HOME/dev" ]; then
        mkdir -p "$HOME/dev"
      fi
    '';

    # -----------------------------------------------------------------------
    # displayHostManualInstructions
    # Prints one-time Linux host instructions from the dedicated NixOS manual
    # document after secrets/wallpaper activation work so operators get one
    # consolidated, post-automation checklist.
    # -----------------------------------------------------------------------
    displayHostManualInstructions =
      lib.hm.dag.entryAfter
        [
          "agentsSkills"
          "agentsSymlink"
          "buildNixIndex"
          "configureObsidianSettings"
          "ensureCustomProvisionSymlinkTargets"
          "finalizeCustomProvisionSymlinks"
          # gitIdentityFromSops, gpgImport, sshKeyAdopt, and verifySecretDecryption
          # are defined in secrets.nix (shared module) but run as Home Manager
          # activations on this host; include them here so manual instructions
          # are always the final output after all activation work.
          "gitIdentityFromSops"
          "gitIgnoreAssemble"
          "gpgImport"
          "installBunPackages"
          "installPwshScriptAnalyzer"
          "installUvTools"
          "prepareCustomProvisionSymlinks"
          "provisionDevDirectory"
          "sshKeyAdopt"
          "syncClawHubSkills"
          "verifySecretDecryption"
          "vsCodeExtensionBridge"
          "vsCodeSymlinks"
          "vsCodeWorkspaceTrust"
          "waitForSopsSecrets"
          "wallpaperProvision"
        ]
        ''
          _manual_path='${config.nucleus.hostManualFile}'
          _repo_root_file="$HOME/.config/nucleus/repo-root"
          _resolved_manual_path="$_manual_path"

          case "$_manual_path" in
            /*) ;;
            *)
              if [ -n "''${NUCLEUS_REPO:-}" ]; then
                _resolved_manual_path="$NUCLEUS_REPO/$_manual_path"
              elif [ -f "$_repo_root_file" ]; then
                _resolved_manual_path="$(cat "$_repo_root_file")/$_manual_path"
              fi
              ;;
          esac

          if [ ! -f "$_resolved_manual_path" ]; then
            echo "linux: host manual not found at $_resolved_manual_path (configured: $_manual_path)." >&2
            exit 1
          fi

          echo "--- MANUAL SETUP (one-time, required) ---" >&2
          /bin/cat "$_resolved_manual_path" >&2
          echo "-------------------------------------------" >&2
        '';
  };

  # --------------------------------------------------------------------------
  # nix-index-update systemd service and timer
  # Keeps the nix-index file database current so pay-respects can suggest
  # `nix profile install` commands when an unknown command is typed.
  #
  # The timer fires daily (00:00, Persistent=true) so the DB stays fresh even
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

  # --------------------------------------------------------------------------
  # jellyfin-media-server systemd user service
  # Runs Jellyfin as the managed user so media-library paths remain inside the
  # same per-user cloud/local storage layout that the rest of this repository
  # configures. Windows uses the vendor service installed by Jellyfin.Server;
  # macOS mirrors this with a user LaunchAgent.
  # --------------------------------------------------------------------------
  systemd.user.services."jellyfin-media-server" = {
    Unit = {
      Description = "Jellyfin media server";
      After = "network.target";
      Wants = "network.target";
    };
    Service = {
      Type = "simple";
      ExecStart = "${jellyfinMediaServer}";
      Restart = "on-failure";
      RestartSec = "30s";
    };
    Install = {
      WantedBy = [ "default.target" ];
    };
  };

  systemd.user.timers."nix-index-update" = {
    Unit = {
      Description = "Daily nix-index database refresh";
    };
    Timer = {
      # Fire daily at 00:00 local time.  Persistent=true ensures the timer
      # catches up on the next login when the machine was off at the
      # scheduled time, preventing the DB from going stale on laptops that
      # are not powered on overnight every day.
      OnCalendar = "00:00:00";
      Persistent = true;
      Unit = "nix-index-update.service";
    };
    Install = {
      WantedBy = [ "timers.target" ];
    };
  };
}
