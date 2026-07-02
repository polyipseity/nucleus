# NixOS/activation.nix — NixOS system activation hooks for the generic Linux host.
#
# All scripts run during nixos-rebuild switch as root.
{
  config,
  lib,
  pkgs,
  ...
}:
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
  # Service watchdog — periodic check for stuck nucleus services.
  # Every 5 minutes, systemd runs the watchdog script which detects services
  # stuck in non-running states and recovers them via reset-failed+restart.
  #
  # Currently the timer runs a no-op placeholder.  When the watchdog script is
  # installed on PATH (via nucleus-service-watchdog package), replace the
  # placeholder with:
  #   script = ''exec nucleus-service-watchdog'';
  #
  # Cross-host parity:
  #   macOS   — launchd agent (modules/macos.nix, StartInterval=300)
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
    path = [ pkgs.jq ];
    environment.NUCLEUS_REPO_ROOT = "/home/polyipseity/dev/nucleus";
    script = ''
      exec ${../../../scripts/service-watchdog.sh}
    '';
    serviceConfig.Type = "oneshot";
  };
}
