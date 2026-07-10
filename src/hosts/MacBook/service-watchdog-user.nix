# MacBook/service-watchdog-user.nix — User-level service watchdog agent.
#
# Checks nucleus-managed user-scope launchd services every 5 minutes
# and recovers any stuck in EX_CONFIG / waiting / spawn-scheduled states.
# Runs as the logged-in user so it can reach ~/Library/LaunchAgents/.
{
  config,
  pkgs,
  nucleusApps,
  ...
}:
let
  nucleusSvcWatchdog = "${nucleusApps.nucleus-service-watchdog}/bin/nucleus-service-watchdog";
  servicesJson = builtins.path {
    path = ../../modules/services.json;
    name = "nucleus-services-json-user";
  };
  repoRoot = "/Users/polyipseity/dev/nucleus";
in
{
  launchd.agents."service-watchdog-user" = {
    enable = true;
    config = {
      Label = "local.service-watchdog-user";
      ProgramArguments = [
        "${pkgs.writeShellScript "svc-watchdog-agent" ''
          exec ${nucleusSvcWatchdog} --domain user
        ''}"
      ];
      StartInterval = 300;
      RunAtLoad = true;
      StandardOutPath = "${config.nucleus.logging.logDir}/service-watchdog/stdout.log";
      StandardErrorPath = "${config.nucleus.logging.logDir}/service-watchdog/stderr.log";
      EnvironmentVariables = {
        NUCLEUS_SERVICES_JSON = servicesJson;
        NUCLEUS_REPO_ROOT = repoRoot;
      };
    };
  };
}
