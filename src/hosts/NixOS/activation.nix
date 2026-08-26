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
  linuxSystemLogDirs = lib.unique (
    lib.flatten (lib.mapAttrsToList (_: svc: svc.logging.dirs.system or [ ]) linuxServices)
  );
  # Bundle services.json into the nix store so the systemd watchdog can
  # read it without needing NUCLEUS_REPO_ROOT.  Same approach as the
  # macOS launchd watchdog (MacBook/service-watchdog.nix).
  servicesJson = import ../../modules/lib/services-json-path.nix { };

  activationBundle = pkgs.callPackage ../../modules/lib/script-tree.nix { };

  # Shared nucleus root constants + activation helpers (Phase 1).
  nucleusRoots = import ../../modules/lib/nucleus-roots.nix { inherit lib pkgs; };
  userHome = config.users.users.${username}.home;

  repoRoot = builtins.getEnv "NUCLEUS_REPO_ROOT";

  # Shared GC application derivations (plan item 6).
  gcApps = import ../../modules/gc-activations.nix { inherit pkgs; };
  inherit (gcApps) logGcSystem nixStoreGc gcWeekly;
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
  # Create system log directories for all nucleus systemd services before they
  # start, so journald/stderr redirect targets exist on disk.  Runs AFTER the
  # root symlinks so <root>/logs resolves into the physical target.
  # ---------------------------------------------------------------------------
  system.activationScripts.nixos-ensure-log-dirs = lib.mkAfter ''
    "${activationBundle}/src/scripts/services/log-dirs-init.sh" \
      "${config.nucleus.logging.systemLogDir}" \
      "${builtins.toString linuxSystemLogDirs}" \
      "" \
      ""
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
        "NUCLEUS_REPO_ROOT=${repoRoot}"
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
        "NUCLEUS_REPO_ROOT=${repoRoot}"
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
