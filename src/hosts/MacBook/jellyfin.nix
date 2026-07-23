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

  jellyfinDaemon = pkgs.writeNucleusShellApplication {
    name = "jellyfin-daemon";
    runtimeInputs = [ pkgs.jellyfin ];
    extraEnv = {
      JELLYFIN_STATE_ROOT = jellyfinStateRoot;
      JELLYFIN_LOG_DIR = "${config.nucleus.logging.systemLogDir}/jellyfin-app";
      JELLYFIN_BIN = "${pkgs.jellyfin}/bin/jellyfin";
    };
    bundleDefault = true;
  };
in
{
  launchd.daemons.jellyfin = {
    serviceConfig = {
      # macOS 26+ SIP blocks unsigned Nix store binaries for system daemons
      # with non-root UserName (EX_CONFIG 78). /bin/sh is Apple-signed and
      # passes SIP gate. See .agents/instructions/macos-launchd-sip.instructions.md.
      # Upstream <https://github.com/nix-darwin/nix-darwin/issues/1219> tracks
      # making launchd services show descriptive names; do not revisit until
      # that issue is resolved.
      ProgramArguments = [
        "/bin/sh"
        "-c"
        "exec ${jellyfinDaemon}/bin/nucleus-jellyfin-daemon"
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
