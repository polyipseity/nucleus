# Declarative rclone mounts and pull-only replicas per user.
# Per-user config in src/users/ under "cloudDrives" domain files.
# Requires FUSE (FUSE-T on macOS, fuse3 on NixOS) and rclone remote configured.
args@{
  config,
  lib,
  pkgs,
  repoRoot,
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

  # Shared enum type aliases — used by both mount and replica submodules.
  providerEnum = lib.types.enum [
    "GoogleDrive"
    "iCloud"
    "OneDrive"
  ];
  iCloudServiceEnum = lib.types.enum [
    "drive"
    "photos"
  ];

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
        description = "Launchd StartCalendarInterval expression (macOS) or systemd OnCalendar string (NixOS) for the fallback timer. Use 'daily' for daily 12:00 execution per repository convention.";
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
      name = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Optional human-readable label for UI surfaces (for example Finder volume names on macOS).";
      };
      id = lib.mkOption {
        type = lib.types.str;
        description = "Unique identifier for this mount entry. Used as part of the launchd / systemd service label.";
      };
      iCloudService = lib.mkOption {
        type = iCloudServiceEnum;
        default = "drive";
        description = "Which Apple service to expose for iCloud entries. Mount commands always pass this explicitly so entry behavior stays aligned with user config even if the shared remote was initially created with a different default service.";
      };
      localPath = lib.mkOption {
        type = lib.types.str;
        description = "Mount target path relative to the user's home directory (e.g. 'clouds/iCloud').";
      };
      provider = lib.mkOption {
        type = providerEnum;
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
        type = lib.types.enum [ "pull" ];
        default = "pull";
        description = "Replica direction. Pull is the supported policy (remote -> local); non-pull values are rejected by replica-sync runners.";
      };
      name = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Optional human-readable label for log messages and UI surfaces (e.g., \"Google Drive\"). When null, the replica `id` is used.";
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
        type = iCloudServiceEnum;
        default = "drive";
        description = "Which Apple service this replica should target for iCloud entries. Keeping it in the shared schema preserves per-user intent even before all replica backends consume the value directly.";
      };
      readWrite = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Whether the replica directory is read-write. When false (the default), the runner locks the local tree as read-only between sync runs. Set true for macOS iCloud where the replica is a symlink to native CloudDocs.";
      };
      localPath = lib.mkOption {
        type = lib.types.str;
        description = "Local replica root path relative to the user's home directory. For iCloud on macOS this documents the native CloudDocs area managed by brctl; for rclone replicas it is the directory rclone syncs into.";
      };
      provider = lib.mkOption {
        type = providerEnum;
        description = "Cloud storage provider. rclone-backed replica scheduling is configured per entry.";
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
  mkMountPoint = mount: "${currentUserHome}/${mount.localPath}";

  mkRcloneMountScript =
    mount:
    let
      mountPoint = mkMountPoint mount;
      rcloneRemote = "${mount.remoteName}:${mount.remotePath}";
      # Always pass the configured iCloud service explicitly so mount behavior
      # follows the per-entry setting even if the shared remote was created
      # with a different default service.
      iCloudServiceArgs = lib.optionals (mount.provider == "iCloud") [
        "--iclouddrive-service"
        mount.iCloudService
      ];
      fsKitBackendArgs = lib.optionals pkgs.stdenv.hostPlatform.isDarwin [
        "--option"
        "backend=fskit"
      ];
      mountVolumeLabel = if mount.name != null then mount.name else mount.id;
      volumeNameArgs = lib.optionals pkgs.stdenv.hostPlatform.isDarwin [
        "--volname"
        mountVolumeLabel
      ];
      readOnlyFlag = lib.optional (!mount.readWrite) "--read-only";
      # Pass the managed config passphrase command when the feature is enabled
      # so the LaunchAgent can decrypt an encrypted rclone.conf on every start.
      # WHY: --password-command not env var: LaunchAgents run outside user shell
      # sessions and do not inherit RCLONE_CONFIG_PASS from the login environment.
      rclonePasswordArgs = lib.optionals config.nucleus.rclone.configPassEnabled [
        "--password-command"
        "cat ${lib.escapeShellArg config.nucleus.rclone.configPassSecretPath}"
      ];
      extraArgsList =
        iCloudServiceArgs ++ fsKitBackendArgs ++ volumeNameArgs ++ rclonePasswordArgs ++ mount.extraArgs;
      fullArgsList = [
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
      ++ readOnlyFlag
      ++ extraArgsList;
    in
    pkgs.writeNucleusShellApplication {
      name = "cloud-mount-${mount.id}";
      runtimeInputs = [ pkgs.rclone ];
      text = ''
        exec ${../scripts/services/rclone-mount.sh} \
          "${mount.remoteName}" \
          "${lib.escapeShellArg rcloneRemote}" \
          "${lib.escapeShellArg mountPoint}" \
          ${lib.escapeShellArgs fullArgsList} \
          "$@"
      '';
    };

  # Build a systemd ExecStop unmount command (NixOS only).
  mkFusermountUnmount =
    # check-suppress:suppression_doc: unmounting a mount that may not exist; cleanup-only operation that must not fail (e.g. on retry after partial mount failure).
    mountPoint: "/bin/sh -c 'fusermount3 -u ${lib.escapeShellArg mountPoint} || true'";

  # Build a scheduled replica-sync runner that invokes
  # scripts/cloud.sh sync for one replica id. NUCLEUS_REPO_ROOT is set by
  # the launchd/systemd service environment. replica_id and user_home are
  # passed as positional args.
  mkReplicaScheduledSyncScript =
    replica:
    pkgs.writeNucleusShellApplication {
      name = "cloud-replica-scheduled-sync-${replica.id}";
      runtimeInputs = [ ];
      text = ''
        exec ${../scripts/services/replica-scheduled-sync.sh} \
          "${lib.escapeShellArg replica.id}" \
          "${currentUserHome}" \
          "$@"
      '';
    };

  # Canonical scheduled-sync timer mapping. Repository policy mandates 12:00 slots.
  mkScheduledSyncLaunchdCalendar =
    interval:
    if interval == "weekly" then
      [
        {
          Hour = 12;
          Minute = 0;
          Weekday = 0;
        }
      ]
    else if interval == "monthly" then
      [
        {
          Hour = 12;
          Minute = 0;
          Day = 1;
        }
      ]
    else
      [
        {
          Hour = 12;
          Minute = 0;
        }
      ];

  mkScheduledSyncSystemdCalendar =
    interval:
    if interval == "weekly" then
      "Sun 12:00:00"
    else if interval == "monthly" then
      "*-*-01 12:00:00"
    else
      "12:00:00";

  activationBundle = pkgs.callPackage ./lib/script-tree.nix { };

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
      scheduledSyncReplicas = builtins.filter (
        r: r.enable && (r.fallbackTimer.enable or true)
      ) config.nucleus.cloudDrives.replicas;
      declaredMountAgents = builtins.filter (m: m.remoteName != null) config.nucleus.cloudDrives.mounts;
      declaredScheduledSyncReplicas = builtins.filter (
        r: (r.fallbackTimer.enable or true)
      ) config.nucleus.cloudDrives.replicas;

      # Mounts require rclone plus an explicit configured remote.
      rcloneMounts = builtins.filter (
        m: m.enable && m.remoteName != null
      ) config.nucleus.cloudDrives.mounts;
    in
    lib.mkMerge [
      # -----------------------------------------------------------------------
      # Shared: directory structure
      # cloud-drives-setup: creates ~/clouds/ and per-entry subdirectories.
      # -----------------------------------------------------------------------
      {
        home.activation.cloud-drives-setup = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
          "${activationBundle}/src/scripts/services/cloud-drives-setup.sh" \
            "${pkgs.jq}/bin/jq" \
            '${builtins.toJSON (map (m: { inherit (m) localPath; }) enabledMounts)}' \
            '${
              builtins.toJSON (
                map (r: {
                  localPath = r.localPath;
                  name = if r.name != null then r.name else r.id;
                  isSpecialICloud =
                    pkgs.stdenv.hostPlatform.isDarwin
                    && r.provider == "iCloud"
                    && r.id == "iCloud"
                    && r.localPath == "clouds/iCloudReplica";
                }) enabledReplicas
              )
            }'
        '';
      }

      # -----------------------------------------------------------------------
      # macOS: LaunchAgents for rclone-backed mounts
      # -----------------------------------------------------------------------
      # This module is imported into the Home Manager config (home-manager.users
      # via sharedModules), so use HM-native launchd.agents with domain = "user"
      # (installs to ~/Library/LaunchAgents) rather than
      # environment.userLaunchAgents, which is a nix-darwin top-level option and
      # does not exist in the HM context.
      (lib.mkIf (pkgs.stdenv.hostPlatform.isDarwin && declaredMountAgents != [ ]) {
        launchd.agents = builtins.listToAttrs (
          map (mount: {
            name = "cloud-mount-${mount.id}";
            value = {
              domain = "user";
              enable = true;
              config = {
                Label = "local.cloud-mount.${mount.id}";
                ProgramArguments = [ "${mkRcloneMountScript mount}/bin/nucleus-cloud-mount-${mount.id}" ];
                RunAtLoad = true;
                # Keep the mount alive; if the remote is not yet configured the
                # wrapper script exits 0, which suppresses the SuccessfulExit
                # restart condition and avoids an aggressive retry loop.
                KeepAlive = {
                  # Restart on crash (non-zero exit) but not on clean exit (exit 0
                  # from the "remote not configured" early-return path above).
                  SuccessfulExit = false;
                };
                # Log errors to ~/Library/Logs for easier debugging.
                # Capture both stdout and stderr so mount activity is fully
                # inspectable (remote not configured, network unavailable, etc.).
                StandardOutPath = "${config.nucleus.logging.logDir}/cloud-mount-${mount.id}/stdout.log";
                StandardErrorPath = "${config.nucleus.logging.logDir}/cloud-mount-${mount.id}/stderr.log";
              };
            };
          }) declaredMountAgents
        );
      })

      # -----------------------------------------------------------------------
      # NixOS: systemd user services for rclone-backed mounts
      # -----------------------------------------------------------------------
      (lib.mkIf (pkgs.stdenv.hostPlatform.isLinux && rcloneMounts != [ ]) {
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
                # WHY: --password-command not env var: systemd user services do not
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
                  Restart = "always";
                };
                Install = {
                  WantedBy = [ "default.target" ];
                };
              };
          }) rcloneMounts
        );
      })

      # -----------------------------------------------------------------------
      # macOS: LaunchAgents for per-replica scheduled replica-sync timers
      # -----------------------------------------------------------------------
      # HM-native launchd.agents with domain = "user" (see mount block note):
      # this module is imported into the Home Manager config, not the darwin
      # config, so environment.userLaunchAgents is not available here.
      (lib.mkIf (pkgs.stdenv.hostPlatform.isDarwin && declaredScheduledSyncReplicas != [ ]) {
        launchd.agents = builtins.listToAttrs (
          map (replica: {
            name = "cloud-replica-scheduled-sync-${replica.id}";
            value = {
              domain = "user";
              enable = true;
              config = {
                Label = "local.cloud-replica-scheduled-sync.${replica.id}";
                ProgramArguments = [
                  "${mkReplicaScheduledSyncScript replica}/bin/nucleus-cloud-replica-scheduled-sync-${replica.id}"
                ];
                EnvironmentVariables = {
                  NUCLEUS_REPO_ROOT = toString repoRoot;
                };
                StartCalendarInterval = mkScheduledSyncLaunchdCalendar replica.fallbackTimer.interval;
                # Keep scheduled sync runs on schedule boundaries only.
                RunAtLoad = false;
                # Capture both stdout and stderr so sync activity is fully
                # inspectable alongside the per-replica sync log.
                StandardOutPath = "${config.nucleus.logging.logDir}/replica-sync-${replica.id}/stdout.log";
                StandardErrorPath = "${config.nucleus.logging.logDir}/replica-sync-${replica.id}/stderr.log";
              };
            };
          }) declaredScheduledSyncReplicas
        );
      })

      # -----------------------------------------------------------------------
      # NixOS: systemd services/timers for per-replica scheduled replica-sync
      # -----------------------------------------------------------------------
      (lib.mkIf (pkgs.stdenv.hostPlatform.isLinux && scheduledSyncReplicas != [ ]) {
        systemd.user.services = builtins.listToAttrs (
          map (replica: {
            name = "cloud-replica-scheduled-sync-${replica.id}";
            value = {
              Unit = {
                Description = "Scheduled replica sync run: ${replica.id}";
                After = "network-online.target";
                Wants = "network-online.target";
              };
              Service = {
                Type = "oneshot";
                ExecStart = "${mkReplicaScheduledSyncScript replica}/bin/nucleus-cloud-replica-scheduled-sync-${replica.id}";
                Environment = "NUCLEUS_REPO_ROOT=${repoRoot}";
              };
              Install = {
                WantedBy = [ "default.target" ];
              };
            };
          }) scheduledSyncReplicas
        );

        systemd.user.timers = builtins.listToAttrs (
          map (replica: {
            name = "cloud-replica-scheduled-sync-${replica.id}";
            value = {
              Unit = {
                Description = "Scheduled replica sync timer: ${replica.id}";
              };
              Timer = {
                OnCalendar = mkScheduledSyncSystemdCalendar replica.fallbackTimer.interval;
                Persistent = true;
                Unit = "cloud-replica-scheduled-sync-${replica.id}.service";
              };
              Install = {
                WantedBy = [ "timers.target" ];
              };
            };
          }) scheduledSyncReplicas
        );
      })
    ];
}
