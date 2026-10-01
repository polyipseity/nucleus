# NixOS/activation.nix - NixOS system activation hooks for the generic Linux host.
# Every script runs during nixos-rebuild switch as root.
{
  config,
  lib,
  pkgs,
  username,
  nucleusApps,
  ...
}:
let
  servicesJSON = builtins.fromJSON (builtins.readFile ../../modules/services.json);
  linuxServices = lib.filterAttrs (
    _: svc: svc ? hosts.NixOS && svc.hosts.NixOS ? type && svc.hosts.NixOS.type != "omitted"
  ) servicesJSON;
  # NOTE: `svc.logging` is read unguarded so a service that omits its `logging`
  # block fails Nix eval loudly instead of being silently skipped.  Only the
  # inner `dirs` level is guarded, since services with no log files omit it.
  linuxSystemLogDirs = lib.unique (
    lib.flatten (
      lib.mapAttrsToList (
        _: svc:
        let
          log = svc.logging;
        in
        (log.dirs or { }).system or [ ]
      ) linuxServices
    )
  );
  # User log dirs are provisioned too and chowned to the service user, since this
  # activation runs as root.  Without it every service that writes a log file
  # would create the dir in its own unit; macOS and Windows provision from the
  # registry.
  linuxUserLogDirs = lib.unique (
    lib.flatten (
      lib.mapAttrsToList (
        _: svc:
        let
          log = svc.logging;
        in
        (log.dirs or { }).user or [ ]
      ) linuxServices
    )
  );
  # Bundle services.json into the nix store so the systemd watchdog reads it
  # without NUCLEUS_REPO_ROOT, like the macOS launchd watchdog.
  servicesJson = import ../../modules/lib/services-json-path.nix { };

  activationBundle = pkgs.callPackage ../../modules/lib/script-tree.nix { };

  nucleusRoots = import ../../modules/lib/nucleus-roots.nix { inherit lib pkgs; };
  userHome = config.users.users.${username}.home;
  userGroup = config.users.users.${username}.group;

  gcApps = import ../../modules/gc-activations.nix { inherit pkgs; };
  inherit (gcApps)
    logGcUser
    logGcSystem
    nixStoreGc
    gcWeekly
    ;
in
{
  # nixos-launch-nvim.sh
  # Deterministic symlink at /etc/nucleus/bin/nvim for vscode-neovim, which does
  # not expand ${userHome} or ~.  The target comes from the home-manager profile
  # directory, so no username is hardcoded (matching useUserPackages = true).
  system.activationScripts.nixos-launch-nvim = lib.mkAfter ''
    "${activationBundle}/src/scripts/editors/launch-nvim.sh" "${
      config.home-manager.users.${username}.home.profileDirectory
    }/bin/nvim"
  '';

  # nixos-nucleus-root-symlinks
  # Create the physical conventional dirs plus root->conventional symlinks
  # BEFORE log-dirs-init, so `mkdir -p <root>/logs` resolves through the symlink
  # into the physical target (e.g. /var/log/nucleus).  Also creates the ~/.nucleus
  # hub for the managed user.  Only activation creates these; services reference
  # root paths only.  All nucleus config lives in the USER root
  # (~/.local/share/nucleus), with no legacy config location.
  system.activationScripts.nixos-nucleus-root-symlinks = lib.mkBefore ''
    ${nucleusRoots.mkNucleusRootSymlinks {
      inherit userHome;
      userName = username;
    }}
    ${nucleusRoots.mkNucleusHub {
      inherit userHome;
      userName = username;
    }}
  '';

  # nixos-ensure-log-dirs
  # Create the system and user log directories for every nucleus systemd service
  # before it starts, chowning user dirs to the service user.
  # WHY: imperative, because it must run AFTER the root symlinks resolve and Nix
  # activation order is alphabetical, not dependency-based.  systemd
  # LogsDirectory creates under /var/log/ (wrong path; nucleus logs live in
  # /var/lib/nucleus/logs/) and StateDirectory creates under /var/lib/ but cannot
  # make nested paths like nucleus/logs/<subdir>.
  system.activationScripts.nixos-ensure-log-dirs = lib.mkAfter ''
    "${activationBundle}/src/scripts/services/log-dirs-init.sh" \
      "${config.nucleus.logging.systemLogDir}" \
      "${builtins.toString linuxSystemLogDirs}" \
      "${builtins.toString linuxUserLogDirs}" \
      "" \
      "${config.nucleus.logging.logDir}" \
      "${userHome}" \
      "${username}:${userGroup}"
  '';

  # System-scope service watchdog for stuck nucleus services, internal 300s sleep
  # loop.  --scope system keeps this root service to system-domain units; a root
  # process has no user manager, so user-domain coverage is a separate unit.
  systemd.services."nucleus-service-watchdog" = {
    description = "Nucleus service watchdog — restart stuck services";
    environment.NUCLEUS_SERVICES_JSON = "${servicesJson}";
    script = "exec ${nucleusApps.nucleus-service-watchdog}/bin/nucleus-service-watchdog --scope system";
    serviceConfig = {
      Restart = "always";
      Type = "simple";
    };
    wantedBy = [ "multi-user.target" ];
  };

  # User-scope watchdog, in the user's own systemd manager so `systemctl --user`
  # resolves; a root process has no user manager and would log a false restart.
  systemd.user.services."nucleus-service-watchdog-user" = {
    description = "Nucleus user service watchdog — restart stuck user services";
    environment.NUCLEUS_SERVICES_JSON = "${servicesJson}";
    serviceConfig = {
      Type = "simple";
      Restart = "always";
      ExecStart = "${nucleusApps.nucleus-service-watchdog}/bin/nucleus-service-watchdog --scope user";
    };
    wantedBy = [ "default.target" ];
  };

  # Daily system log rotation.  Root, because user-context gc cannot write
  # root-owned service logs.
  systemd.services."nucleus-log-gc-system" = {
    description = "Daily system log rotation for nucleus services";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${logGcSystem}/bin/nucleus-log-gc-system";
      Environment = [
        "NUCLEUS_LOG_EXPIRY=${config.nucleus.logging.rotation.expiry}"
      ];
    };
  };

  systemd.timers."nucleus-log-gc-system" = {
    description = "Daily system log rotation timer";
    timerConfig = {
      OnCalendar = "12:00:00";
      Persistent = true;
    };
    wantedBy = [ "timers.target" ];
  };

  # Daily user log rotation, as the user rather than root.
  systemd.user.services."nucleus-log-gc-user" = {
    description = "Daily user log rotation for nucleus services";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${logGcUser}/bin/nucleus-log-gc-user";
      Environment = [
        "NUCLEUS_LOG_EXPIRY=${config.nucleus.logging.rotation.expiry}"
      ];
    };
  };

  systemd.user.timers."nucleus-log-gc-user" = {
    description = "Daily user log rotation timer";
    timerConfig = {
      OnCalendar = "12:00:00";
      Persistent = true;
    };
    wantedBy = [ "timers.target" ];
  };

  # Daily Nix store GC: intersection generation prune plus collect-garbage.
  systemd.services."nucleus-nix-store-gc" = {
    description = "Daily Nix store garbage collection";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${nixStoreGc}/bin/nucleus-nix-store-gc";
      Environment = [
        "NUCLEUS_GC_EXPIRY=${config.modules.gc.expiry}"
        "NUCLEUS_GC_NIX_EXPIRY=${config.modules.gc.nixStoreExpiry}"
        "NUCLEUS_GC_GENERATIONS_KEEP=${toString config.modules.gc.generationsKeep}"
        "NUCLEUS_GC_SYSTEM_GENERATIONS_KEEP=${toString config.modules.gc.systemGenerationsKeep}"
      ];
    };
  };

  systemd.timers."nucleus-nix-store-gc" = {
    description = "Daily Nix store garbage collection timer";
    timerConfig = {
      OnCalendar = "12:00:00";
      Persistent = true;
    };
    wantedBy = [ "timers.target" ];
  };

  # Weekly full gc.sh as root, with the user steps via sudo -u.
  systemd.services."nucleus-gc-weekly" = {
    description = "Weekly garbage collection (VM, build, cache artifacts)";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${gcWeekly}/bin/nucleus-gc-weekly";
      Environment = [
        "NUCLEUS_GC_EXPIRY=${config.modules.gc.expiry}"
        "NUCLEUS_LOG_EXPIRY=${config.nucleus.logging.rotation.expiry}"
        "NUCLEUS_GC_GENERATIONS_KEEP=${toString config.modules.gc.generationsKeep}"
        "NUCLEUS_USERNAME=${username}"
      ];
    };
  };

  systemd.timers."nucleus-gc-weekly" = {
    description = "Weekly garbage collection timer";
    timerConfig = {
      OnCalendar = "Sun *-*-* 12:00:00";
      Persistent = true;
    };
    wantedBy = [ "timers.target" ];
  };

  # nixos-verify-nucleus-services
  # Warn-only check that every managed service runs after activation: a service
  # that fails to start should not block activation, but the warning surfaces it
  # for post-apply investigation.
  system.activationScripts.nixos-verify-nucleus-services = lib.mkAfter ''
    if command -v nucleus-svc >/dev/null 2>&1; then
      if ! nucleus-svc verify; then
        echo "svc: warning: some services are inactive (non-fatal; check journalctl for details)" >&2
      fi
    fi
  '';
}
