# NixOS/activation.nix — NixOS system activation hooks for the generic Linux host.
#
# All scripts run during nixos-rebuild switch as root.
{
  config,
  lib,
  pkgs,
  nucleusApps,
  ...
}:
let
  servicesJSON = builtins.fromJSON (builtins.readFile ../../modules/services.json);
  linuxServices = lib.filterAttrs (
    name: svc:
    svc ? platforms.nixos && svc.platforms.nixos ? type && svc.platforms.nixos.type != "omitted"
  ) servicesJSON;
  linuxSystemLogDirs = lib.unique (
    lib.flatten (lib.mapAttrsToList (name: svc: svc.logging.dirs.system or [ ]) linuxServices)
  );
in
{
  # ---------------------------------------------------------------------------
  # nvimLauncher
  # Creates a deterministic symlink at /etc/nucleus-bin/nvim that
  # vscode-neovim can use (the extension does not expand ${userHome} or ~).
  # Resolves the nvim path from the home-manager profile directory so that no
  # username is hardcoded, matching Home Manager's useUserPackages = true layout.
  # ---------------------------------------------------------------------------
  system.activationScripts.nvimLauncher = lib.mkAfter ''
    _nvim_real="${config.home-manager.users.polyipseity.home.profileDirectory}/bin/nvim"
    if [ -x "$_nvim_real" ]; then
      mkdir -p /etc/nucleus-bin
      ln -sfn "$_nvim_real" /etc/nucleus-bin/nvim
    fi
  '';

  # ---------------------------------------------------------------------------
  # ensureLogDirs
  # Create system log directories for all nucleus systemd services before they
  # start, so journald/stderr redirect targets exist on disk.
  # ---------------------------------------------------------------------------
  system.activationScripts.ensureLogDirs = lib.mkAfter ''
    system_log_dir="${config.nucleus.logging.systemLogDir}"
    for subdir in ${builtins.toString linuxSystemLogDirs}; do
      mkdir -p "$system_log_dir/$subdir"
    done
  '';

  # ---------------------------------------------------------------------------
  # Service watchdog — periodic check for stuck nucleus services.
  # Every 5 minutes, systemd runs the watchdog script which detects services
  # stuck in non-running states and recovers them via reset-failed+restart.
  #
  # Cross-host parity:
  #   macOS   — launchd agent/daemon (StartInterval=300)
  #   NixOS   — this systemd timer (OnUnitActiveSec=5min)
  #   Windows — scheduled task (scheduler.dsc.yml, PT5M repetition)
  # ---------------------------------------------------------------------------
  systemd.timers."nucleus-service-watchdog" = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "5min";
      OnUnitActiveSec = "5min";
    };
  };

  systemd.services."nucleus-service-watchdog" = {
    description = "Nucleus service watchdog — restart stuck services";
    path = with nucleusApps; [
      nucleus-service-watchdog
      pkgs.jq
    ];
    environment.NUCLEUS_REPO_ROOT = "/home/polyipseity/dev/nucleus";
    script = ''
      exec nucleus-service-watchdog
    '';
    serviceConfig.Type = "oneshot";
  };

  # ---------------------------------------------------------------------------
  # Service activation verification
  # Warn-only check that all managed services are running after activation.
  # Failing to start a service should not block activation, but the warning
  # surfaces issues for post-apply investigation.
  # ---------------------------------------------------------------------------
  system.activationScripts.verifyNucleusServices = lib.mkAfter ''
    if command -v nucleus-svc >/dev/null 2>&1; then
      if ! nucleus-svc verify; then
        echo "svc: some services are inactive (non-fatal; check journalctl for details)" >&2
      fi
    fi
  '';
}
