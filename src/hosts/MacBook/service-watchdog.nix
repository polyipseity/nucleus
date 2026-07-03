# MacBook/service-watchdog.nix — Periodic service watchdog for launchd services.
#
# Runs every 5 minutes, detects services stuck in EX_CONFIG / waiting /
# spawn-scheduled states, and recovers them via bootout+bootstrap.
# Handles services whose KeepAlive launchd daemons exited with a non-retryable
# code (exit 78 = EX_CONFIG) and would otherwise stay in penalty box forever.
{
  config,
  pkgs,
  lib,
  nucleusApps,
  username,
  ...
}:
let
  nucleusSvcWatchdog = "${nucleusApps.nucleus-service-watchdog}/bin/nucleus-service-watchdog";
in
{
  launchd.daemons."service-watchdog" = {
    serviceConfig = {
      Label = "local.service-watchdog";
      ProgramArguments = [
        "${pkgs.writeShellScript "svc-watchdog-daemon" ''
          exec ${nucleusSvcWatchdog}
        ''}"
      ];
      StartInterval = 300;
      RunAtLoad = true;
      UserName = username;
      KeepAlive = false;
      StandardOutPath = "${config.nucleus.logging.systemLogDir}/service-watchdog/stdout.log";
      StandardErrorPath = "${config.nucleus.logging.systemLogDir}/service-watchdog/stderr.log";
    };
  };
}
