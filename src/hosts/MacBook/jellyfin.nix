# MacBook/jellyfin.nix - one shared Jellyfin instance for the whole host instead
# of a LaunchAgent per Home Manager user. HTTPS comes from the shared
# https-proxy module; this file declares the daemon and its virtual host.
# Source: https://jellyfin.org/docs/general/post-install/networking/reverse-proxy/
{
  config,
  lib,
  pkgs,
  username,
  ...
}:
let
  jellyfinHttpPort = 8096;
  jellyfinStateRoot = "/Users/Shared/Jellyfin";

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
    NIX_SSL_CERT_FILE = resolveValue "NIX_SSL_CERT_FILE";
    NUCLEUS_HOST = resolveValue "NUCLEUS_HOST";
  };

  jellyfinDaemon = pkgs.writeNucleusShellApplication {
    name = "jellyfin-daemon";
    runtimeInputs = [ pkgs.jellyfin ];
    scriptName = "src/scripts/services/jellyfin-daemon";
  };
in
{
  launchd.daemons.jellyfin = {
    serviceConfig = {
      # macOS 26+ SIP blocks unsigned Nix store binaries for system daemons with
      # a non-root UserName (EX_CONFIG 78), and /bin/sh is Apple-signed.
      # ref: macos-service-hardening.instructions.md - SIP /bin/sh wrapper
      # Do not revisit until
      # <https://github.com/nix-darwin/nix-darwin/issues/1219> is resolved.
      ProgramArguments = [
        "/bin/sh"
        "-c"
        "exec ${jellyfinDaemon}/bin/nucleus-jellyfin-daemon '${jellyfinStateRoot}' '${config.nucleus.logging.systemLogDir}/jellyfin-app' '${pkgs.jellyfin}/bin/jellyfin'"
      ];
      KeepAlive = true;
      RunAtLoad = true;
      UserName = username;
      EnvironmentVariables = daemonEnv;
      StandardOutPath = "${config.nucleus.logging.systemLogDir}/jellyfin/stdout.log";
      StandardErrorPath = "${config.nucleus.logging.systemLogDir}/jellyfin/stderr.log";
    };
  };

  nucleus.httpsProxy.virtualHosts.jellyfin = {
    listenPort = 8920;
    upstreamPort = jellyfinHttpPort;
  };
}
