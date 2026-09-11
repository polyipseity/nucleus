# NixOS/activation.nix — NixOS system activation hooks for the generic Linux host.
#
# All scripts run during nixos-rebuild switch as root.
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
  # NOTE: `svc.logging` is accessed unguarded so a service that omits its
  # `logging` block fails Nix eval loudly (instead of being silently skipped).
  # `dirs` may be absent (services with no log files), so only that level is
  # guarded with `or {}` / `or []`.
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
  # User log dirs are provisioned too, and chowned to the service user, because this
  # activation runs as root: without it every NixOS service that writes a log file would
  # have to create the dir in its own unit (macOS and Windows provision from the registry).
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
  # Bundle services.json into the nix store so the systemd watchdog can
  # read it without needing NUCLEUS_REPO_ROOT.  Same approach as the
  # macOS launchd watchdog (MacBook/service-watchdog.nix).
  servicesJson = import ../../modules/lib/services-json-path.nix { };

  activationBundle = pkgs.callPackage ../../modules/lib/script-tree.nix { };

  # Shared nucleus root constants + activation helpers (Phase 1).
  nucleusRoots = import ../../modules/lib/nucleus-roots.nix { inherit lib pkgs; };
  userHome = config.users.users.${username}.home;
  userGroup = config.users.users.${username}.group;

  # Shared GC application derivations (plan item 6).
  gcApps = import ../../modules/gc-activations.nix { inherit pkgs; };
  inherit (gcApps)
    logGcUser
    logGcSystem
    nixStoreGc
    gcWeekly
    ;
in
{
  # ---------------------------------------------------------------------------
  # nixos-launch-nvim.sh
  # Creates a deterministic symlink at /etc/nucleus/bin/nvim that
  # vscode-neovim can use (the extension does not expand ${userHome} or ~).
  # Resolves the nvim path from the home-manager profile directory so that no
  # username is hardcoded, matching Home Manager's useUserPackages = true layout.
  # ---------------------------------------------------------------------------
  system.activationScripts.nixos-launch-nvim = lib.mkAfter ''
    "${activationBundle}/src/scripts/editors/launch-nvim.sh" "${
      config.home-manager.users.${username}.home.profileDirectory
    }/bin/nvim"
  '';

  # ---------------------------------------------------------------------------
  # nixos-nucleus-root-symlinks
  # Create the physical conventional dirs + root→conventional symlinks BEFORE
  # log-dirs-init so `mkdir -p <root>/logs` resolves through the symlink into
  # the physical target (e.g. /var/log/nucleus).  Also creates the ~/.nucleus
  # hub (user → USER root, system → SYSTEM root) for the managed user.
  # Activation (and ONLY activation) creates these; services reference only
  # root paths.  All nucleus config lives directly in the USER root
  # (~/.local/share/nucleus) — there is no legacy config location.
  # ---------------------------------------------------------------------------
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

  # ---------------------------------------------------------------------------
  # nixos-ensure-log-dirs
  # Create system and user log directories for all nucleus systemd services before they
  # start, chowning the user dirs to the service user.
  # WHY: Log directory creation is imperative because it must run AFTER the
  # root symlinks resolve (Nix activation ordering is alphabetical, not
  # dependency-based). systemd LogsDirectory creates under /var/log/ (wrong
  # path — nucleus logs live under /var/lib/nucleus/logs/). StateDirectory
  # creates under /var/lib/ but cannot create nested paths like
  # nucleus/logs/<subdir>. Neither handles the activation ordering constraint.
  # ---------------------------------------------------------------------------
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

  # ---------------------------------------------------------------------------
  # Service watchdog — persistent daemon for stuck nucleus services.
  # Internal 300s sleep loop.  Cross-host parity:
  #   macOS   — launchd daemon (KeepAlive=true, internal 300s loop)
  #   NixOS   — systemd service (Restart=always, internal 300s loop)
  #   Windows — scheduled task AtStartup (internal 300s loop)
  # ---------------------------------------------------------------------------
  systemd.services."nucleus-service-watchdog" = {
    description = "Nucleus service watchdog — restart stuck services";
    environment.NUCLEUS_SERVICES_JSON = "${servicesJson}";
    script = "exec ${nucleusApps.nucleus-service-watchdog}/bin/nucleus-service-watchdog";
    serviceConfig = {
      Restart = "always";
      Type = "simple";
    };
    wantedBy = [ "multi-user.target" ];
  };

  # ---------------------------------------------------------------------------
  # Daily system log rotation — rotates /var/log/nucleus as root because
  # user-context gc cannot write root-owned service logs.
  # ---------------------------------------------------------------------------
  systemd.services."nucleus-log-gc-system" = {
    description = "Daily system log rotation for nucleus services";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${logGcSystem}/bin/nucleus-log-gc-system";
      Environment = [
        "NUCLEUS_GC_EXPIRY=${config.modules.gc.expiry}"
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

  # ---------------------------------------------------------------------------
  # Daily user log rotation — rotates ~/.local/share/nucleus/logs as the
  # user (not root). Cross-host parity with macOS launchd agent and
  # Windows scheduled task.
  # ---------------------------------------------------------------------------
  systemd.user.services."nucleus-log-gc-user" = {
    description = "Daily user log rotation for nucleus services";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${logGcUser}/bin/nucleus-log-gc-user";
      Environment = [
        "NUCLEUS_GC_EXPIRY=${config.modules.gc.expiry}"
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

  # ---------------------------------------------------------------------------
  # Daily Nix store GC — intersection generation prune + collect-garbage.
  # ---------------------------------------------------------------------------
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

  # ---------------------------------------------------------------------------
  # Weekly garbage collection — full gc.sh as root with user steps via sudo -u.
  # ---------------------------------------------------------------------------
  systemd.services."nucleus-gc-weekly" = {
    description = "Weekly garbage collection (VM, build, cache artifacts)";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${gcWeekly}/bin/nucleus-gc-weekly";
      Environment = [
        "NUCLEUS_GC_EXPIRY=${config.modules.gc.expiry}"
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

  # ---------------------------------------------------------------------------
  # nixos-verify-nucleus-services
  # Warn-only check that all managed services are running after activation.
  # Failing to start a service should not block activation, but the warning
  # surfaces issues for post-apply investigation.
  # ---------------------------------------------------------------------------
  system.activationScripts.nixos-verify-nucleus-services = lib.mkAfter ''
    if command -v nucleus-svc >/dev/null 2>&1; then
      if ! nucleus-svc verify; then
        echo "svc: warning: some services are inactive (non-fatal; check journalctl for details)" >&2
      fi
    fi
  '';
}
