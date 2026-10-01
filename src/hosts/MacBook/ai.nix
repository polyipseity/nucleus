# MacBook/ai.nix — System-wide AI inference daemons on macOS.
#
# launchd.daemons, not launchd.agents: inference servers and gateways serve
# every user and start at boot, not at login.
{
  config,
  lib,
  pkgs,
  username,
  ...
}:
let
  userHome = "/Users/${username}";
  litellmConfig = "${userHome}/Library/Application Support/nucleus/litellm-config.yml";
  litellmLogConfig = "${userHome}/Library/Application Support/nucleus/logging_config.json";
  secrets = builtins.fromJSON (builtins.readFile ../../modules/env/env-secrets.json);
  envLib = import ../../modules/lib/env-secrets.nix {
    inherit
      config
      pkgs
      lib
      username
      ;
    hostName = "MacBook";
  };
  secretArgs = envLib.mkSecretArgsForConsumer {
    inherit config secrets;
    consumer = "litellm";
  };

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
  litellmEnv = lib.filterAttrs (_name: value: value != null) {
    NIX_SSL_CERT_FILE = resolveValue "NIX_SSL_CERT_FILE";
    NUCLEUS_HOST = resolveValue "NUCLEUS_HOST";
    REDIS_HOST = resolveValue "REDIS_HOST";
    REDIS_PORT = resolveValue "REDIS_PORT";
    REDIS_USERNAME = resolveValue "REDIS_USERNAME";
  };
  # OLLAMA_HOST is left out: the server must bind the default port, not the
  # LiteLLM proxy port. The gui-env LaunchAgent sets it for CLI clients.
  ollamaEnv =
    litellmEnv
    // lib.filterAttrs (_name: value: value != null) {
      OLLAMA_FLASH_ATTENTION = resolveValue "OLLAMA_FLASH_ATTENTION";
      OLLAMA_CONTEXT_LENGTH = resolveValue "OLLAMA_CONTEXT_LENGTH";
      OLLAMA_KV_CACHE_TYPE = resolveValue "OLLAMA_KV_CACHE_TYPE";
    };

  litellmDaemon = pkgs.writeNucleusShellApplication {
    name = "litellm-daemon";
    runtimeInputs = [ pkgs.litellm ];
    scriptName = "src/scripts/services/litellm-daemon";
  };

  servicesJSON = builtins.fromJSON (builtins.readFile ../../modules/services.json);
  redisCfg = servicesJSON.redis.network.default;
in
{
  # The Redis server is declared by src/modules/redis.nix, not here.

  # A dotted key becomes `org.nixos.<key>` in the generated label, so keep the
  # keys dot-free to match what `services.json` expects.
  launchd.daemons."litellm" = {
    serviceConfig = {
      Label = "local.litellm";
      # macOS 26+ SIP blocks unsigned Nix store binaries for system daemons
      # with non-root UserName (EX_CONFIG 78). /bin/sh is Apple-signed and
      # ref: macos-service-hardening.instructions.md -- SIP /bin/sh wrapper
      ProgramArguments = [
        "/bin/sh"
        "-c"
        "exec ${litellmDaemon}/bin/nucleus-litellm-daemon '${litellmConfig}' '60' ${
          lib.concatStringsSep " " (map (arg: "'${arg}'") secretArgs)
        }"
      ];
      KeepAlive = true;
      RunAtLoad = true;
      UserName = username;
      # launchd has no ordering primitive, so the daemon waits for Redis to
      # accept connections before starting. Ticks match the keyfile poll
      # timeout, which covers the boot-time race with local.redis.
      EnvironmentVariables = litellmEnv // {
        LITELLM_REDIS_POLL_TICKS = "60";
        LITELLM_REDIS_HOST = redisCfg.host;
        LITELLM_REDIS_PORT = toString redisCfg.port;
        LITELLM_LOG_CONFIG = litellmLogConfig;
        PYTHONPATH = "${userHome}/Library/Application Support/nucleus";
      };
      StandardOutPath = "${config.nucleus.logging.systemLogDir}/litellm/stdout.log";
      StandardErrorPath = "${config.nucleus.logging.systemLogDir}/litellm/stderr.log";
    };
  };

  # With no KEYFILE:ENVVAR pair the daemon starts and every `default` request
  # fails with "Missing credentials", which happens when the catalog and
  # sops.secrets disagree. Fail fast naming the missing secret.
  assertions = [
    {
      assertion =
        (builtins.length secrets.secrets == 0)
        || (
          builtins.length secretArgs
          == builtins.length (builtins.filter (s: builtins.elem "litellm" s.consumers) secrets.secrets)
        );
      message =
        "litellm: env-secrets catalog declares ${toString (builtins.length secrets.secrets)} secret(s) but only ${toString (builtins.length secretArgs)} KEYFILE:ENVVAR pair(s) resolved.  Check src/modules/env/env-secrets.json and sops.secrets. Missing: "
        + lib.concatStringsSep ", " (
          map (e: e.name) (builtins.filter (e: !(config.sops.secrets ? ${e.name})) secrets.secrets)
        );
    }
  ];

  launchd.daemons."ollama" = {
    serviceConfig = {
      Label = "local.ollama";
      # macOS 26+ SIP blocks unsigned Nix store binaries for system daemons
      # with non-root UserName (EX_CONFIG 78). /bin/sh is Apple-signed and
      # ref: macos-service-hardening.instructions.md -- SIP /bin/sh wrapper
      ProgramArguments = [
        "/bin/sh"
        "-c"
        "exec ${pkgs.ollama}/bin/ollama serve"
      ];
      KeepAlive = true;
      RunAtLoad = true;
      UserName = username;
      EnvironmentVariables = ollamaEnv;
      StandardOutPath = "${config.nucleus.logging.systemLogDir}/ollama/stdout.log";
      StandardErrorPath = "${config.nucleus.logging.systemLogDir}/ollama/stderr.log";
    };
  };
}
