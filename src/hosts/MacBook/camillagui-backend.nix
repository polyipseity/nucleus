# hosts/MacBook/camillagui-backend.nix — CamillaDSP GUI launchd service.
#
# Runs as the primary user via UserName so the daemon can access user-level
# config at $HOME/.config/camillagui-backend/. Config is deployed by Home
# Manager in modules/home.nix.
{
  config,
  lib,
  pkgs,
  username,
  ...
}:

let
  userHome = config.users.users.${username}.home;
  envVars = import ../../modules/lib/env-catalog.nix {
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
    NIX_SSL_CERT_FILE = resolveValue "NIX_SSL_CERT_FILE";
    NUCLEUS_HOST = resolveValue "NUCLEUS_HOST";
  };
in
{
  launchd.daemons."camillagui-backend" = {
    serviceConfig = {
      Label = "local.camillagui-backend";
      # ref: macos-service-hardening.instructions.md -- SIP /bin/sh wrapper (reference pattern)
      ProgramArguments = [
        "/bin/sh"
        "-c"
        "exec ${pkgs.camillagui-backend}/bin/camillagui-backend -c ${userHome}/.config/camillagui-backend/config.yml"
      ];
      UserName = username;
      EnvironmentVariables = daemonEnv;
      KeepAlive = true;
      RunAtLoad = true;
      StandardOutPath = "${config.nucleus.logging.systemLogDir}/camillagui-backend/stdout.log";
      StandardErrorPath = "${config.nucleus.logging.systemLogDir}/camillagui-backend/stderr.log";
    };
  };
}
