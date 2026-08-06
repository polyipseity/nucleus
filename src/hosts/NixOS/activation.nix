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
    _: svc: svc ? platforms.nixos && svc.platforms.nixos ? type && svc.platforms.nixos.type != "omitted"
  ) servicesJSON;
  linuxSystemLogDirs = lib.unique (
    lib.flatten (lib.mapAttrsToList (_: svc: svc.logging.dirs.system or [ ]) linuxServices)
  );
  # Bundle services.json into the nix store so the systemd watchdog can
  # read it without needing NUCLEUS_REPO_ROOT.  Same approach as the
  # macOS launchd watchdog (MacBook/service-watchdog.nix).
  servicesJson = builtins.path {
    path = ../../modules/services.json;
    name = "nucleus-services-json";
  };

  activationBundle = pkgs.callPackage ../../modules/lib/script-tree.nix { };

  repoRoot = builtins.getEnv "NUCLEUS_REPO_ROOT";

  logGcSystem = pkgs.writeNucleusShellApplication {
    name = "log-gc-system";
    runtimeInputs = [ pkgs.jq ];
    scriptName = "src/scripts/services/log-gc-system";
  };
in
{
  # ---------------------------------------------------------------------------
  # nixos-launch-nvim.sh
  # Creates a deterministic symlink at /etc/nucleus-bin/nvim that
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
  # nixos-ensure-log-dirs
  # Create system log directories for all nucleus systemd services before they
  # start, so journald/stderr redirect targets exist on disk.
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
    path = with nucleusApps; [
      nucleus-service-watchdog
      pkgs.jq
    ];
    environment.NUCLEUS_SERVICES_JSON = "${servicesJson}";
    script = ''
      exec nucleus-service-watchdog
    '';
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
      Environment = "NUCLEUS_REPO_ROOT=${repoRoot}";
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
  # nixos-verify-nucleus-services
  # Warn-only check that all managed services are running after activation.
  # Failing to start a service should not block activation, but the warning
  # surfaces issues for post-apply investigation.
  # ---------------------------------------------------------------------------
  system.activationScripts.nixos-verify-nucleus-services = lib.mkAfter ''
    if command -v nucleus-svc >/dev/null 2>&1; then
      if ! nucleus-svc verify; then
        echo "svc: some services are inactive (non-fatal; check journalctl for details)" >&2
      fi
    fi
  '';
}
