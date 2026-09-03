# MacBook/ai.nix — System-wide AI inference daemons on macOS.
#
# Provides:
#   • Ollama — launchd system daemon (127.0.0.1:11434)
#   • LiteLLM — launchd system daemon (127.0.0.1:4000)
#
# Why system daemons (launchd.daemons) instead of user agents (launchd.agents):
# Inference servers and API gateways serve all users and should start at boot,
# not after login.  The corresponding Home Manager module
# (modules/ai/default.nix) provides the ollama CLI, OLLAMA_HOST session
# variable, and oterm client.
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
  catalog = import ../../modules/env-catalog.nix;
  envLib = import ../../modules/lib/env-catalog.nix {
    inherit
      config
      pkgs
      lib
      username
      ;
    hostName = "MacBook";
  };
  keyArgs = envLib.mkKeyArgs { inherit config catalog; };

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
  # Daemon env vars from the centralized catalog.
  # Provides NIX_SSL_CERT_FILE (HTTPS) and NUCLEUS_HOST (host identity).
  litellmEnv = lib.filterAttrs (_name: value: value != null) {
    NIX_SSL_CERT_FILE = resolveValue "NIX_SSL_CERT_FILE";
    NUCLEUS_HOST = resolveValue "NUCLEUS_HOST";
    REDIS_HOST = resolveValue "REDIS_HOST";
    REDIS_PORT = resolveValue "REDIS_PORT";
    REDIS_USERNAME = resolveValue "REDIS_USERNAME";
  };
  # Ollama daemon env vars: OLLAMA_* runtime tunables excluding OLLAMA_HOST.
  # OLLAMA_HOST is excluded because the ollama server must bind to the default
  # port (11434), not the LiteLLM proxy port (4000).  OLLAMA_HOST is set by
  # the gui-env LaunchAgent for CLI clients that should route through the
  # proxy.
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

  # Centralized service registry — single source of truth for network config.
  servicesJSON = builtins.fromJSON (builtins.readFile ../../modules/services.json);
  # Redis endpoint for LiteLLM consumer wiring (the Redis server itself is
  # owned by the shared src/modules/redis.nix module).
  redisCfg = servicesJSON.redis.network.default;
in
{
  # Local Redis instance for LiteLLM coordination and response caching is
  # provided by the shared src/modules/redis.nix module (launchd.daemons."redis").

  # Keys without a dot become `local.<key>` in launchd; keys with a dot become
  # `org.nixos.<key>`. Keep keys dot-free so the generated label matches
  # `services.json` (which expects `local.litellm`/`local.ollama`).
  launchd.daemons."litellm" = {
    serviceConfig = {
      # Explicit label to match services.json (which expects local.litellm).
      # Without this, nix-darwin auto-generates org.nixos.litellm.
      Label = "local.litellm";
      # macOS 26+ SIP blocks unsigned Nix store binaries for system daemons
      # with non-root UserName (EX_CONFIG 78). /bin/sh is Apple-signed and
      # ref: macos-service-hardening.instructions.md -- SIP /bin/sh wrapper
      ProgramArguments = [
        "/bin/sh"
        "-c"
        "exec ${litellmDaemon}/bin/nucleus-litellm-daemon '${litellmConfig}' '60' ${
          lib.concatStringsSep " " (map (arg: "'${arg}'") keyArgs)
        }"
      ];
      KeepAlive = true;
      RunAtLoad = true;
      UserName = username;
      # launchd has no native ordering primitive, so the litellm daemon waits
      # for the local Redis server to accept connections before starting
      # (opt-in via LITELLM_REDIS_POLL_TICKS; set here to match the keyfile
      # poll timeout so boot-time races with local.redis are covered).
      EnvironmentVariables = litellmEnv // {
        LITELLM_REDIS_POLL_TICKS = "60";
        LITELLM_REDIS_HOST = redisCfg.host;
        LITELLM_REDIS_PORT = toString redisCfg.port;
      };
      StandardOutPath = "${config.nucleus.logging.systemLogDir}/litellm/stdout.log";
      StandardErrorPath = "${config.nucleus.logging.systemLogDir}/litellm/stderr.log";
    };
  };

  # Guard: if the env catalog declares AI keys but the resolved keyArgs is
  # empty, the LiteLLM daemon would start with no API-key pairs and every
  # `default` request fails with "Missing credentials". This happens when the
  # catalog (src/modules/env-catalog.nix) is out of sync with sops.secrets
  # (e.g. a key was added to the catalog but not to system.yml). Fail fast
  # with a clear message naming the missing secret.
  assertions = [
    {
      assertion =
        (builtins.length catalog.keys == 0) || (builtins.length keyArgs == builtins.length catalog.keys);
      message =
        "litellm: env catalog declares ${toString (builtins.length catalog.keys)} secret(s) but only ${toString (builtins.length keyArgs)} KEYFILE:ENVVAR pair(s) resolved.  Check src/modules/env-catalog.nix and sops.secrets. Missing: "
        + lib.concatStringsSep ", " (
          map (e: e.name) (builtins.filter (e: !(config.sops.secrets ? ${e.name})) catalog.keys)
        );
    }
  ];

  launchd.daemons."ollama" = {
    serviceConfig = {
      # Explicit label to match services.json (which expects local.ollama).
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
      # Source: src/modules/lib/env-catalog.nix (OLLAMA_* entries).
      # The catalog is the canonical list for these values.  OLLAMA_HOST
      # is excluded so the daemon binds to the default port (11434).  OLLAMA_HOST
      # is set by the gui-env LaunchAgent for CLI clients.
      EnvironmentVariables = ollamaEnv;
      StandardOutPath = "${config.nucleus.logging.systemLogDir}/ollama/stdout.log";
      StandardErrorPath = "${config.nucleus.logging.systemLogDir}/ollama/stderr.log";
    };
  };
}
