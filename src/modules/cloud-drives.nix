# modules/cloud-drives.nix — Declarative cloud drive mounts and replicas.
#
# Manages two categories of cloud storage access per POSIX user:
#
#   Mounts — persistent rclone mount processes providing on-demand access via
#             FUSE (requires macFUSE on macOS, fuse3 on NixOS). Files are read
#             from the remote on access; no full local copy is kept.
#
#   Replicas — full local copies of remote data, kept in sync by rclone
#              bisync / rclone sync.
#
# Configuration: per-user settings come from src/modules/users.json under the
# "cloudDrives" key. Multiple mounts and replicas may be declared per user,
# even for the same provider but with different accounts or paths (each entry
# needs a unique "id" string).
#
# macOS prerequisites:
#   - macFUSE (Homebrew cask macfuse) for rclone FUSE mounts. macOS mounts
#     use the FSKit backend and therefore live under /Volumes, with the legacy
#     home-directory paths symlinked back to those mountpoints for convenience.
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
      iCloudService = lib.mkOption {
        type = lib.types.enum [
          "drive"
          "photos"
        ];
        default = "drive";
        description = "Which Apple service to expose for iCloud entries. Mount commands always pass this explicitly so entry behavior stays aligned with user config even if the shared remote was initially created with a different default service.";
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
        description = "Cloud storage provider. All providers use rclone remotes and require remoteName for active mounts.";
      };
      readWrite = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Whether the mount is read-write. Set false to pass --read-only to rclone mount.";
      };
      remoteName = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "rclone remote name as configured via 'rclone config'.";
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
      iCloudService = lib.mkOption {
        type = lib.types.enum [
          "drive"
          "photos"
        ];
        default = "drive";
        description = "Which Apple service this replica should target for iCloud entries. Keeping it in the shared schema preserves per-user intent even before all replica backends consume the value directly.";
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
        description = "Cloud storage provider. rclone-backed replica scheduling is configured per entry.";
      };
      realtime = lib.mkOption {
        type = replicaRealtimeSubmodule;
        default = { };
        description = "Near-realtime filesystem-event-driven sync settings.";
      };
      remoteName = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "rclone remote name.";
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
  mkMountPoint =
    mount:
    if pkgs.stdenv.isDarwin then
      "/Volumes/nucleus-cloud-${mount.id}"
    else
      "${currentUserHome}/${mount.localPath}";

  mkMountLink = mount: "${currentUserHome}/${mount.localPath}";

  mkRcloneMountScript =
    mount:
    let
      mountPoint = mkMountPoint mount;
      rcloneRemote = "${mount.remoteName}:${mount.remotePath}";
      rcloneConfigPassExport = lib.optionalString config.nucleus.rclone.configPassEnabled ''
      export RCLONE_CONFIG_PASS="$(cat ${lib.escapeShellArg config.nucleus.rclone.configPassSecretPath})"
      '';
      # Always pass the configured iCloud service explicitly so mount behavior
      # follows the per-entry setting even if the shared remote was created
      # with a different default service.
      iCloudServiceArgs = lib.optionals (mount.provider == "iCloud") [
        "--iclouddrive-service"
        mount.iCloudService
      ];
      fsKitBackendArgs = lib.optionals pkgs.stdenv.isDarwin [
        "--option"
        "backend=fskit"
      ];
      readOnlyFlag = lib.optional (!mount.readWrite) "--read-only";
      # Pass the managed config passphrase command when the feature is enabled
      # so the LaunchAgent can decrypt an encrypted rclone.conf on every start.
      # WHY --password-command not env var: LaunchAgents run outside user shell
      # sessions and do not inherit RCLONE_CONFIG_PASS from the login environment.
      rclonePasswordArgs = lib.optionals config.nucleus.rclone.configPassEnabled [
        "--password-command"
        "cat ${lib.escapeShellArg config.nucleus.rclone.configPassSecretPath}"
      ];
      extraArgsList = iCloudServiceArgs ++ fsKitBackendArgs ++ rclonePasswordArgs ++ mount.extraArgs;
    in
    pkgs.writeShellScript "cloud-mount-${mount.id}" ''
      set -eu

      ${rcloneConfigPassExport}

      # Verify the rclone remote is configured; exit 0 (no restart) if not.
      if ! rclone_remotes="$(${pkgs.rclone}/bin/rclone listremotes)"; then
        echo "cloud-drives: failed to list rclone remotes for '${mount.remoteName}' mount; check the config passphrase and remote configuration." >&2
        exit 1
      fi

      case "$rclone_remotes" in
        *${lib.escapeShellArg "${mount.remoteName}:"}*)
          ;;
        *)
        echo "cloud-drives: rclone remote '${mount.remoteName}' not configured; mount skipped." >&2
        echo "cloud-drives: run 'rclone config' to set up the remote, then re-run 'home-manager switch'." >&2
        exit 0
          ;;
      esac

      # macFUSE/FSKit creates the volume mountpoint itself under /Volumes.
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

      # Mounts require rclone plus an explicit configured remote.
      rcloneMounts = builtins.filter (
        m: m.enable && m.remoteName != null
      ) config.nucleus.cloudDrives.mounts;

      hasRcloneProvider =
        rcloneMounts != [ ]
        || builtins.any (r: r.enable && r.remoteName != null) config.nucleus.cloudDrives.replicas;
    in
    lib.mkMerge [
      # -----------------------------------------------------------------------
      # Shared: rclone package installation
      # -----------------------------------------------------------------------
      (lib.mkIf hasRcloneProvider {
        home.packages = [ pkgs.rclone ];
      })

      # -----------------------------------------------------------------------
      # Shared: directory structure
      # cloudDrivesSetup: creates ~/clouds/ and per-entry subdirectories.
      # -----------------------------------------------------------------------
      {
        home.activation.cloudDrivesSetup = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
          set -eu

          # Create the top-level clouds/ directory tree. macOS mounts live under
          # /Volumes for FSKit compatibility, so we symlink the legacy home
          # paths back to those mountpoints.
          mkdir -p "$HOME/clouds"

          ensure_cloud_mount_link() {
            _target="$1"
            _link="$2"

            mkdir -p "$(/usr/bin/dirname "$_link")"

            if [ -L "$_link" ]; then
              _current_target="$(/usr/bin/readlink "$_link")"
              if [ "$_current_target" = "$_target" ]; then
                return 0
              fi
              /bin/rm "$_link"
            elif [ -e "$_link" ]; then
              # WHY: the legacy home path is only a mountpoint, so replacing an
              # old directory with a symlink is safe once the old mount is gone.
              if /sbin/mount | /usr/bin/grep -F " on $_link (" >/dev/null 2>&1; then
                echo "macos: cloud mount path '$_link' is still mounted; unmount it before rerunning activation." >&2
                return 0
              fi
              /bin/rm -rf "$_link"
            fi

            /bin/ln -s "$_target" "$_link"
          }

          ${lib.concatStringsSep "\n" (
            map (m: ''
              ${lib.optionalString pkgs.stdenv.isDarwin ''
                ensure_cloud_mount_link ${lib.escapeShellArg (mkMountPoint m)} ${lib.escapeShellArg (mkMountLink m)}
              ''}
              ${lib.optionalString (!pkgs.stdenv.isDarwin) ''
                mkdir -p ${lib.escapeShellArg (mkMountLink m)}
              ''}
            '') enabledMounts
          )}

          ${lib.concatStringsSep "\n" (
            map (r: ''
              if [ ! -L "$HOME/${r.localPath}" ]; then
                mkdir -p "$HOME/${r.localPath}"
              fi
            '') enabledReplicas
          )}
        '';
      }

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
                iCloudServiceArgs = lib.optionals (mount.provider == "iCloud") [
                  "--iclouddrive-service"
                  mount.iCloudService
                ];
                readOnlyFlag = lib.optional (!mount.readWrite) "--read-only";
                # Same password-command logic as the macOS LaunchAgent script.
                # WHY --password-command not env var: systemd user services do not
                # inherit session environment variables set in shell profiles.
                rclonePasswordArgs = lib.optionals config.nucleus.rclone.configPassEnabled [
                  "--password-command"
                  "cat ${lib.escapeShellArg config.nucleus.rclone.configPassSecretPath}"
                ];
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
                    ++ map lib.escapeShellArg (
                      readOnlyFlag ++ iCloudServiceArgs ++ rclonePasswordArgs ++ mount.extraArgs
                    )
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
