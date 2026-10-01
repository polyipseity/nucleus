# MacBook/service-watchdog.nix - Periodic service watchdog for launchd services.
#
# Recovers services stuck in EX_CONFIG (exit 78), waiting, or spawn-scheduled,
# which launchd would otherwise leave in the penalty box.
{
  config,
  lib,
  pkgs,
  nucleusApps,
  username,
  ...
}:
let
  nucleusSvcWatchdog = "${nucleusApps.nucleus-service-watchdog}/bin/nucleus-service-watchdog";
  # launchd-rooted daemons cannot read an iCloud Drive path, even through the
  # ~/dev/nucleus symlink, so services.json is bundled into the store.
  servicesJson = import ../../modules/lib/services-json-path.nix { };

  envVars = import ../../modules/lib/env-secrets.nix {
    inherit
      config
      pkgs
      lib
      username
      ;
    hostName = "MacBook";
  };
  resolveValue = name: envVars.resolveValue name "MacBook";
  daemonEnv = lib.filterAttrs (_name: value: value != null) {
    # launchd sets no HOME for a root daemon, and lib.sh needs one for
    # derive_nucleus_user_root(). Root's macOS home is always /var/root.
    HOME = "/var/root";
    NIX_SSL_CERT_FILE = resolveValue "NIX_SSL_CERT_FILE";
    NUCLEUS_HOST = resolveValue "NUCLEUS_HOST";
  };
in
{
  launchd.daemons."service-watchdog" = {
    serviceConfig = {
      Label = "local.service-watchdog";
      # ref: macos-service-hardening.instructions.md -- SIP /bin/sh wrapper
      # Upstream <https://github.com/nix-darwin/nix-darwin/issues/1219> owns
      # descriptive launchd names; leave the label alone until it lands.
      ProgramArguments = [
        "/bin/sh"
        "-c"
        "exec ${nucleusSvcWatchdog} --scope system"
      ];
      RunAtLoad = true;
      KeepAlive = true;
      EnvironmentVariables = daemonEnv // {
        NUCLEUS_SERVICES_JSON = servicesJson;
      };
      StandardOutPath = "${config.nucleus.logging.systemLogDir}/service-watchdog/stdout.log";
      StandardErrorPath = "${config.nucleus.logging.systemLogDir}/service-watchdog/stderr.log";
    };
  };
}
