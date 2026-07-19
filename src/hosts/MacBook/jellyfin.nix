# MacBook/jellyfin.nix — Host-level singleton Jellyfin daemon + HTTPS ingress.
#
# Runs one shared Jellyfin instance for the whole host instead of one
# LaunchAgent per Home Manager user.
#
# HTTPS is provided by the shared https-proxy module; this file only declares
# the Jellyfin daemon and the virtual host entry for the proxy.
#
# Sources:
# - https://jellyfin.org/docs/general/post-install/networking/reverse-proxy/
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

  envVars = import ../../modules/lib/env-catalog.nix {
    inherit
      config
      pkgs
      lib
      username
      ;
  };
  resolveValue = name: envVars.resolveValue name "macOS";
  daemonEnv = lib.filterAttrs (_name: value: value != null) {
    NIX_SSL_CERT_FILE = resolveValue "NIX_SSL_CERT_FILE";
    NUCLEUS_HOST = resolveValue "NUCLEUS_HOST";
  };

  jellyfinDaemon = pkgs.writeShellScript "jellyfin-daemon" (
    builtins.replaceStrings
      [ "__JELLYFIN_STATE_ROOT__" "__JELLYFIN_LOG_DIR__" "__JELLYFIN_BIN__" ]
      [
        jellyfinStateRoot
        "${config.nucleus.logging.systemLogDir}/jellyfin-app"
        "${pkgs.jellyfin}/bin/jellyfin"
      ]
      (builtins.readFile ../../scripts/hosts/MacBook/macos-jellyfin-daemon.sh)
  );
in
{
  launchd.daemons.jellyfin = {
    serviceConfig = {
      # macOS 26+ SIP blocks unsigned Nix store binaries for system daemons
      # with non-root UserName (EX_CONFIG 78). /bin/sh is Apple-signed and
      # passes SIP gate. See .agents/instructions/macos-launchd-sip.instructions.md.
      ProgramArguments = [
        "/bin/sh"
        "-c"
        "exec ${jellyfinDaemon}"
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
