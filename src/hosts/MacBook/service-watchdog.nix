# MacBook/service-watchdog.nix — Periodic service watchdog for launchd services.
#
# Runs every 5 minutes, detects services stuck in EX_CONFIG / waiting /
# spawn-scheduled states, and recovers them via bootout+bootstrap.
# Handles services whose KeepAlive launchd daemons exited with a non-retryable
# code (exit 78 = EX_CONFIG) and would otherwise stay in penalty box forever.
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
  # Bundle services.json into the nix store so launchd-rooted daemons
  # can read it — they cannot access iCloud Drive paths even through
  # the ~/dev/nucleus symlink (macOS sandbox restriction).
  servicesJson = builtins.path {
    path = ../../modules/services.json;
    name = "nucleus-services-json";
  };
in
{
  launchd.daemons."service-watchdog" = {
    serviceConfig = {
      Label = "local.service-watchdog";
      ProgramArguments = [
        "${pkgs.writeShellScript "svc-watchdog-daemon" ''
          exec ${nucleusSvcWatchdog} --domain system
        ''}"
      ];
      StartInterval = 300;
      RunAtLoad = true;
      KeepAlive = false;
      EnvironmentVariables =
        (import ../../modules/lib/env-vars.nix {
          inherit
            config
            pkgs
            lib
            username
            ;
        }).toMacOSDaemonEnv
        // {
          NUCLEUS_SERVICES_JSON = servicesJson;
        };
      StandardOutPath = "${config.nucleus.logging.systemLogDir}/service-watchdog/stdout.log";
      StandardErrorPath = "${config.nucleus.logging.systemLogDir}/service-watchdog/stderr.log";
    };
  };
}
