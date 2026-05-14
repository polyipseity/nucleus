# modules/cloud-drives.nix — Declarative cloud drive mounts and replicas.
#
# Manages two categories of cloud storage access per POSIX user:
#
#   Mounts — persistent rclone mount processes providing on-demand access via
#             FUSE (requires macFUSE on macOS, fuse3 on NixOS). Files are read
#             from the remote on access; no full local copy is kept. On macOS,
#             an iCloud mount is a stable symlink to the native CloudDocs path
#             (~/Library/Mobile Documents/com~apple~CloudDocs) — no rclone
#             process is needed because the OS already provides live access.
#
#   Replicas — full local copies of remote data, kept in sync by rclone
#              bisync / rclone sync. The macOS iCloud replica is special: it
#              uses the native `brctl download` command (CloudDocs mechanism)
#              rather than rclone, because macOS already manages iCloud Drive
#              synchronisation and `brctl` is the correct way to force local
#              availability. This activation replaces the former
#              ensureICloudFilesLocal hook that lived in macos.nix.
#
# Configuration: per-user settings come from src/modules/users.json under the
# "cloudDrives" key. Multiple mounts and replicas may be declared per user,
# even for the same provider but with different accounts or paths (each entry
# needs a unique "id" string).
#
# macOS prerequisites:
#   - macFUSE (Homebrew cask macfuse) for rclone FUSE mounts
#   - rclone remote configured via `rclone config` before the LaunchAgent fires
#
# NixOS prerequisites:
#   - programs.fuse.enable = true in the system-level NixOS configuration
#   - rclone remote configured via `rclone config` before the service starts
args@{
  config,
  lib,
  pkgs,
  ...
}:
let
  users = args.users or { };
  currentUsername = config.home.username;
  currentUserHome = config.home.homeDirectory;

  userConfig =
    users.${currentUsername}.cloudDrives or {
      mounts = [ ];
      replicas = [ ];
    };

  # ---------------------------------------------------------------------------
  # Option type definitions
  # ---------------------------------------------------------------------------

  replicaRealtimeSubmodule = lib.types.submodule {
    options = {
      debounceSeconds = lib.mkOption {
        type = lib.types.int;
        default = 5;
        description = "Seconds to wait after the last filesystem event before triggering a sync run.";
      };
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Whether to enable filesystem-event-driven near-realtime sync.";
      };
    };
  };

  replicaFallbackTimerSubmodule = lib.types.submodule {
    options = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Whether to enable a periodic fallback sync timer (backstop for missed filesystem events).";
      };
      interval = lib.mkOption {
        type = lib.types.str;
        default = "daily";
        description = "Launchd StartCalendarInterval expression (macOS) or systemd OnCalendar string (NixOS) for the fallback timer. Use 'daily' for daily 00:00 execution per repository convention.";
      };
    };
  };

  mountSubmodule = lib.types.submodule {
    options = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Whether to activate this mount. Defaults to true; set false to declare but disable.";
      };
      extraArgs = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "Extra command-line arguments to pass to rclone mount (non-iCloud providers only).";
      };
      id = lib.mkOption {
        type = lib.types.str;
        description = "Unique identifier for this mount entry. Used as part of the launchd / systemd service label.";
      };
      localPath = lib.mkOption {
        type = lib.types.str;
        description = "Mount target path relative to the user's home directory (e.g. 'clouds/iCloud').";
      };
      provider = lib.mkOption {
        type = lib.types.enum [
          "GoogleDrive"
          "iCloud"
          "OneDrive"
        ];
        description = "Cloud storage provider. 'iCloud' on macOS uses a native CloudDocs symlink; on NixOS it falls back to rclone and requires remoteName.";
      };
      readWrite = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Whether the mount is read-write. Set false to pass --read-only to rclone mount.";
      };
      remoteName = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "rclone remote name as configured via 'rclone config'. Null is valid for iCloud on macOS where the native CloudDocs path is used instead.";
      };
      remotePath = lib.mkOption {
        type = lib.types.str;
        default = "/";
        description = "Path within the rclone remote to mount.";
      };
    };
  };

  replicaSubmodule = lib.types.submodule {
    options = {
      direction = lib.mkOption {
        type = lib.types.enum [
          "bidirectional"
          "pull"
          "push"
        ];
        default = "bidirectional";
        description = "Sync direction: pull copies remote to local, push copies local to remote, bidirectional uses rclone bisync.";
      };
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Whether to activate this replica. Defaults to false; must be explicitly opted in.";
      };
      fallbackTimer = lib.mkOption {
        type = replicaFallbackTimerSubmodule;
        default = { };
        description = "Periodic fallback sync timer settings (backstop for missed filesystem events).";
      };
      filtersFile = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Absolute or home-relative path to a rclone filters file. Null means no filters applied.";
      };
      id = lib.mkOption {
        type = lib.types.str;
        description = "Unique identifier for this replica entry. Used as part of service labels.";
      };
      localPath = lib.mkOption {
        type = lib.types.str;
        description = "Local replica root path relative to the user's home directory. For iCloud on macOS this documents the native CloudDocs area managed by brctl; for rclone replicas it is the directory rclone syncs into.";
      };
      provider = lib.mkOption {
        type = lib.types.enum [
          "GoogleDrive"
          "iCloud"
          "OneDrive"
        ];
        description = "Cloud storage provider. 'iCloud' on macOS uses native brctl; on NixOS it requires remoteName.";
      };
      realtime = lib.mkOption {
        type = replicaRealtimeSubmodule;
        default = { };
        description = "Near-realtime filesystem-event-driven sync settings.";
      };
      remoteName = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "rclone remote name. Null is valid for iCloud on macOS where brctl is used instead.";
      };
      remotePath = lib.mkOption {
        type = lib.types.str;
        default = "/";
        description = "Path within the rclone remote to replicate.";
      };
    };
  };

  # ---------------------------------------------------------------------------
  # Internal helper computations (evaluated inside config to avoid ordering
  # issues with the options fixed-point)
  # ---------------------------------------------------------------------------

  # Build a rclone mount wrapper script for macOS LaunchAgents.
  # Uses the full Nix store path to rclone so the agent is not PATH-dependent.
  mkRcloneMountScript =
    mount:
    let
      mountPoint = "${currentUserHome}/${mount.localPath}";
      rcloneRemote = "${mount.remoteName}:${mount.remotePath}";
      readOnlyFlag = lib.optional (!mount.readWrite) "--read-only";
      extraArgsList = mount.extraArgs;
    in
    pkgs.writeShellScript "cloud-mount-${mount.id}" ''
      set -eu

      # Ensure mount directory exists before rclone tries to use it.
      mkdir -p ${lib.escapeShellArg mountPoint}

      # Verify the rclone remote is configured; exit 0 (no restart) if not.
      if ! ${pkgs.rclone}/bin/rclone listremotes 2>/dev/null | grep -qF ${lib.escapeShellArg "${mount.remoteName}:"}; then
        echo "cloud-drives: rclone remote '${mount.remoteName}' not configured; mount skipped." >&2
        echo "cloud-drives: run 'rclone config' to set up the remote, then re-run 'home-manager switch'." >&2
        exit 0
      fi

      exec ${pkgs.rclone}/bin/rclone mount \
        ${lib.escapeShellArg rcloneRemote} \
        ${lib.escapeShellArg mountPoint} \
        --vfs-cache-mode full \
        --vfs-cache-max-age 1h \
        --dir-cache-time 5m \
        --poll-interval 1m \
        --log-level ERROR \
        ${lib.concatStringsSep " \\\n    " (map lib.escapeShellArg (readOnlyFlag ++ extraArgsList))}
    '';

  # Build a systemd ExecStop unmount command (NixOS only).
  mkFusermountUnmount =
    mountPoint: "/bin/sh -c 'fusermount3 -u ${lib.escapeShellArg mountPoint} || true'";

in
{
  options.nucleus.cloudDrives = {
    mounts = lib.mkOption {
      type = lib.types.listOf mountSubmodule;
      default = userConfig.mounts;
      description = "List of cloud drive mounts for this user. Each entry is independently addressable via its 'id' field; multiple entries for the same provider are allowed (e.g. two Google Drive accounts).";
    };

    replicas = lib.mkOption {
      type = lib.types.listOf replicaSubmodule;
      default = userConfig.replicas;
      description = "List of cloud drive replicas for this user. Each replica keeps a full local copy of the remote data. Defaults to disabled; each entry must set enable = true to activate.";
    };
  };

  config =
    let
      enabledMounts = builtins.filter (m: m.enable) config.nucleus.cloudDrives.mounts;
      enabledReplicas = builtins.filter (r: r.enable) config.nucleus.cloudDrives.replicas;

      # Mounts that need an rclone process:
      #   - non-iCloud providers always use rclone (needs remoteName set)
      #   - iCloud on macOS uses a native CloudDocs symlink (no rclone process)
      #   - iCloud on NixOS would need rclone but is unsupported for now
      rcloneMounts = builtins.filter (
        m: m.enable && m.remoteName != null && !(m.provider == "iCloud" && pkgs.stdenv.isDarwin)
      ) config.nucleus.cloudDrives.mounts;

      # iCloud mounts on macOS (symlink path, no rclone process).
      iCloudMountsMacOS = builtins.filter (
        m: m.enable && m.provider == "iCloud" && pkgs.stdenv.isDarwin
      ) config.nucleus.cloudDrives.mounts;

      # iCloud replicas on macOS (use native brctl, not rclone).
      iCloudReplicasMacOS = builtins.filter (
        r: r.enable && r.provider == "iCloud" && pkgs.stdenv.isDarwin
      ) config.nucleus.cloudDrives.replicas;

      hasRcloneProvider =
        rcloneMounts != [ ]
        || builtins.any (
          r: r.enable && r.remoteName != null && !(r.provider == "iCloud" && pkgs.stdenv.isDarwin)
        ) config.nucleus.cloudDrives.replicas;
    in
    lib.mkMerge [
      # -----------------------------------------------------------------------
      # Shared: rclone package installation
      # -----------------------------------------------------------------------
      (lib.mkIf hasRcloneProvider {
        home.packages = [ pkgs.rclone ];
      })

      # -----------------------------------------------------------------------
      # Shared: directory structure and iCloud symlinks
      # cloudDrivesSetup: creates ~/clouds/, per-entry subdirectories, and the
      # macOS iCloud CloudDocs symlinks for mount and replica paths.
      # -----------------------------------------------------------------------
      {
        home.activation.cloudDrivesSetup = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
          set -eu

          protect_cloud_symlink() {
            _cloud_symlink_path="$1"
            if ! /usr/bin/chflags -h uchg "$_cloud_symlink_path"; then
              echo "cloud-drives: warning — could not protect symlink $_cloud_symlink_path with uchg." >&2
            fi
          }

          unprotect_cloud_symlink() {
            _cloud_symlink_path="$1"
            if ! /usr/bin/chflags -h nouchg "$_cloud_symlink_path"; then
              echo "cloud-drives: warning — could not clear uchg from symlink $_cloud_symlink_path before update." >&2
            fi
          }

          # Create the top-level clouds/ directory tree.
          mkdir -p "$HOME/clouds"

          ${lib.concatStringsSep "\n" (
            map (m: ''
              if [ ! -L "$HOME/${m.localPath}" ] && [ "${m.provider}" != "iCloud" ]; then
                mkdir -p "$HOME/${m.localPath}"
              fi
            '') enabledMounts
          )}

          ${lib.concatStringsSep "\n" (
            map (r: ''
              if [ ! -L "$HOME/${r.localPath}" ] && [ "${r.provider}" != "iCloud" ]; then
                mkdir -p "$HOME/${r.localPath}"
              fi
            '') enabledReplicas
          )}

          ${lib.optionalString (iCloudMountsMacOS != [ ]) (
            lib.concatStringsSep "\n" (
              map (m: ''
                # iCloud mount on macOS: stable symlink to the native CloudDocs root.
                # The OS manages live access; no rclone process is needed here.
                _icloud_native="$HOME/Library/Mobile Documents/com~apple~CloudDocs"
                _icloud_link="$HOME/${m.localPath}"
                if [ -d "$_icloud_native" ]; then
                  if [ -L "$_icloud_link" ] && [ "$(readlink "$_icloud_link")" = "$_icloud_native" ]; then
                    protect_cloud_symlink "$_icloud_link"
                    : # Correct symlink already in place; no-op.
                  elif [ -e "$_icloud_link" ] && [ ! -L "$_icloud_link" ]; then
                    echo "cloud-drives: $HOME/${m.localPath} is not a symlink — merge any wanted content and remove it, then re-run apply." >&2
                    exit 1
                  else
                    if [ -L "$_icloud_link" ]; then
                      unprotect_cloud_symlink "$_icloud_link"
                    fi
                    ln -sf "$_icloud_native" "$_icloud_link"
                    protect_cloud_symlink "$_icloud_link"
                    echo "cloud-drives: linked $HOME/${m.localPath} -> $_icloud_native" >&2
                  fi
                else
                  echo "cloud-drives: iCloud Drive not found at $_icloud_native; skipping ${m.id} mount symlink." >&2
                fi
              '') iCloudMountsMacOS
            )
          )}

          ${lib.optionalString (iCloudReplicasMacOS != [ ]) (
            lib.concatStringsSep "\n" (
              map (r: ''
                # iCloud replica on macOS: stable symlink to the native Mobile Documents root.
                # WHY: this keeps replica paths under ~/clouds while exposing the full
                # iCloud-managed directory tree exactly as requested.
                _icloud_native="$HOME/Library/Mobile Documents"
                _icloud_link="$HOME/${r.localPath}"
                if [ -d "$_icloud_native" ]; then
                  if [ -L "$_icloud_link" ] && [ "$(readlink "$_icloud_link")" = "$_icloud_native" ]; then
                    protect_cloud_symlink "$_icloud_link"
                    : # Correct symlink already in place; no-op.
                  elif [ -e "$_icloud_link" ] && [ ! -L "$_icloud_link" ]; then
                    echo "cloud-drives: $HOME/${r.localPath} is not a symlink — merge any wanted content and remove it, then re-run apply." >&2
                    exit 1
                  else
                    if [ -L "$_icloud_link" ]; then
                      unprotect_cloud_symlink "$_icloud_link"
                    fi
                    ln -sf "$_icloud_native" "$_icloud_link"
                    protect_cloud_symlink "$_icloud_link"
                    echo "cloud-drives: linked $HOME/${r.localPath} -> $_icloud_native" >&2
                  fi
                else
                  echo "cloud-drives: iCloud Drive not found at $_icloud_native; skipping ${r.id} replica symlink." >&2
                fi
              '') iCloudReplicasMacOS
            )
          )}
        '';
      }

      # -----------------------------------------------------------------------
      # macOS: brctl iCloud replica refresh
      # cloudDrivesICloudRefresh: forces all iCloud-synced files to download
      # locally. Replaces the former ensureICloudFilesLocal hook in macos.nix.
      # Only runs when at least one iCloud replica is enabled.
      # -----------------------------------------------------------------------
      (lib.mkIf (iCloudReplicasMacOS != [ ]) {
        home.activation.cloudDrivesICloudRefresh = lib.hm.dag.entryAfter [ "reloadUserPreferenceState" ] ''
          set +e  # soft-fail: iCloud may not be configured on all machines

          ICLOUD_BASE="$HOME/Library/Mobile Documents/com~apple~CloudDocs"

          if [ ! -d "$ICLOUD_BASE" ]; then
            set -e
            exit 0  # iCloud not initialised on this machine; nothing to do.
          fi

          echo "cloud-drives: forcing iCloud files to download locally..." >&2

          # brctl download is the official macOS command for forcing CloudKit
          # file state to download-complete.  It is part of /usr/bin/brctl
          # (available on all modern macOS releases) and targets the main
          # iCloud Drive root (excluding app-specific iCloud containers).
          # WHY 2>/dev/null on the glob expansion: the glob may expand to
          # paths that brctl cannot process (e.g. lock files); errors on
          # individual paths are benign and should not abort the activation.
          if ! /usr/bin/brctl download "$ICLOUD_BASE"/* 2>/dev/null; then
            echo "cloud-drives: warning — brctl download did not complete; files may download on first access." >&2
          else
            echo "cloud-drives: iCloud files forced to local cache." >&2
          fi

          set -e
        '';
      })

      # -----------------------------------------------------------------------
      # macOS: LaunchAgents for rclone-backed mounts
      # -----------------------------------------------------------------------
      (lib.mkIf (pkgs.stdenv.isDarwin && rcloneMounts != [ ]) {
        launchd.agents = builtins.listToAttrs (
          map (mount: {
            name = "cloud-mount-${mount.id}";
            value = {
              enable = true;
              config = {
                Label = "local.cloud-mount.${mount.id}";
                ProgramArguments = [ "${mkRcloneMountScript mount}" ];
                RunAtLoad = true;
                # Keep the mount alive; if the remote is not yet configured the
                # wrapper script exits 0, which suppresses the SuccessfulExit
                # restart condition and avoids an aggressive retry loop.
                KeepAlive = {
                  # Restart on crash (non-zero exit) but not on clean exit (exit 0
                  # from the "remote not configured" early-return path above).
                  SuccessfulExit = false;
                };
                # Throttle restarts to 30 s to avoid rapid cycling while the
                # remote is being set up.
                ThrottleInterval = 30;
                # Log errors to ~/Library/Logs for easier debugging.
                # WHY not /dev/null: mount failures are actionable (e.g. remote
                # not configured, network unavailable) and should be inspectable.
                StandardOutPath = "/dev/null";
                StandardErrorPath = "${currentUserHome}/Library/Logs/cloud-mount-${mount.id}.log";
              };
            };
          }) rcloneMounts
        );
      })

      # -----------------------------------------------------------------------
      # NixOS: systemd user services for rclone-backed mounts
      # -----------------------------------------------------------------------
      (lib.mkIf (pkgs.stdenv.isLinux && rcloneMounts != [ ]) {
        systemd.user.services = builtins.listToAttrs (
          map (mount: {
            name = "cloud-mount-${mount.id}";
            value =
              let
                mountPoint = "${currentUserHome}/${mount.localPath}";
                rcloneRemote = "${mount.remoteName}:${mount.remotePath}";
                readOnlyFlag = lib.optional (!mount.readWrite) "--read-only";
              in
              {
                Unit = {
                  Description = "rclone cloud mount: ${mount.id} (${mount.provider})";
                  After = "network-online.target";
                  Wants = "network-online.target";
                };
                Service = {
                  Type = "simple";
                  ExecStartPre = "/bin/sh -c 'mkdir -p ${lib.escapeShellArg mountPoint}'";
                  ExecStart = lib.concatStringsSep " " (
                    [
                      "${pkgs.rclone}/bin/rclone"
                      "mount"
                      (lib.escapeShellArg rcloneRemote)
                      (lib.escapeShellArg mountPoint)
                      "--vfs-cache-mode"
                      "full"
                      "--vfs-cache-max-age"
                      "1h"
                      "--dir-cache-time"
                      "5m"
                      "--poll-interval"
                      "1m"
                      "--log-level"
                      "ERROR"
                    ]
                    ++ map lib.escapeShellArg (readOnlyFlag ++ mount.extraArgs)
                  );
                  ExecStop = mkFusermountUnmount mountPoint;
                  Restart = "on-failure";
                  RestartSec = "30s";
                };
                Install = {
                  WantedBy = [ "default.target" ];
                };
              };
          }) rcloneMounts
        );
      })
    ];
}
