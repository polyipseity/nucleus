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
    name: svc:
    svc ? platforms.nixos && svc.platforms.nixos ? type && svc.platforms.nixos.type != "omitted"
  ) servicesJSON;
  linuxSystemLogDirs = lib.unique (
    lib.flatten (lib.mapAttrsToList (name: svc: svc.logging.dirs.system or [ ]) linuxServices)
  );
  # Bundle services.json into the nix store so the systemd watchdog can
  # read it without needing NUCLEUS_REPO_ROOT.  Same approach as the
  # macOS launchd watchdog (MacBook/service-watchdog.nix).
  servicesJson = builtins.path {
    path = ../../modules/services.json;
    name = "nucleus-services-json";
  };
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
    NUCLEUS_NVIM_PATH="${config.home-manager.users.${username}.home.profileDirectory}/bin/nvim"
    ${builtins.readFile ../../scripts/host/nixos/nixos-activation-setup.sh}
  '';

  # ---------------------------------------------------------------------------
  # ensureLogDirs
  # Create system log directories for all nucleus systemd services before they
  # start, so journald/stderr redirect targets exist on disk.
  # ---------------------------------------------------------------------------
  system.activationScripts.ensureLogDirs = lib.mkAfter ''
    NUCLEUS_SYSTEM_LOG_DIR="${config.nucleus.logging.systemLogDir}"
    NUCLEUS_LOG_SUBDIRS="${builtins.toString linuxSystemLogDirs}"
    ${builtins.readFile ../../scripts/host/nixos/nixos-activation-setup.sh}
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
  # Service activation verification
  # Warn-only check that all managed services are running after activation.
  # Failing to start a service should not block activation, but the warning
  # surfaces issues for post-apply investigation.
  # ---------------------------------------------------------------------------
  system.activationScripts.verifyNucleusServices = lib.mkAfter ''
    ${builtins.readFile ../../scripts/host/nixos/nixos-activation-setup.sh}
  '';
}
