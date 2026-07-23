# hosts/MacBook/https-proxy.nix — HTTPS proxy launchd service.
#
# Service-manager-specific fragment imported alongside the shared module.
# The shared option definitions are in src/modules/https-proxy.nix.
{
  config,
  lib,
  pkgs,
  username,
  ...
}:

let
  servicesJSON = builtins.fromJSON (builtins.readFile ../../modules/services.json);
  caddyAdminAddr = "${servicesJSON.caddy.network.admin.host}:${toString servicesJSON.caddy.network.admin.port}";
  cfg = config.nucleus.httpsProxy;

  # Generate a Caddyfile from all configured virtual hosts.
  caddyfile = pkgs.writeText "https-proxy.Caddyfile" (
    let
      globalConfig = ''
        {
          admin ${caddyAdminAddr}
          auto_https disable_redirects
        }
      '';

      virtualHostConfigs = lib.mapAttrsToList (_name: vh: ''
        https://${vh.hostname}:${toString vh.listenPort} {
          bind 127.0.0.1 ::1
          tls internal
          reverse_proxy ${vh.upstreamHost}:${toString vh.upstreamPort}
        ${lib.optionalString (vh.extraConfig != "") (
          lib.concatMapStringsSep "\n" (line: "  ${line}") (lib.splitString "\n" vh.extraConfig)
        )}
        }
      '') cfg.virtualHosts;
    in
    globalConfig + "\n" + builtins.concatStringsSep "\n" virtualHostConfigs
  );

  proxyDaemon = pkgs.writeNucleusShellApplication {
    name = "https-proxy-daemon";
    runtimeInputs = [ pkgs.caddy ];
    extraEnv = {
      CADDYFILE_PATH = caddyfile;
    };
  };

  systemLogDir = config.nucleus.logging.systemLogDir;

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
in
{
  launchd.daemons.httpsProxy = {
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
        "exec ${proxyDaemon}/bin/nucleus-https-proxy-daemon"
      ];
      KeepAlive = true;
      RunAtLoad = true;
      UserName = username;
      EnvironmentVariables = daemonEnv;
      StandardOutPath = "${systemLogDir}/caddy/stdout.log";
      StandardErrorPath = "${systemLogDir}/caddy/stderr.log";
    };
  };
}
