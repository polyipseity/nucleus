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
  # Data-driven key args: read key catalog to build KEYFILE:ENVVAR pairs.
  # The catalog is emitted as a Nix expression by ensure_key_catalog so it is
  # importable under pure evaluation (an absolute user-path JSON is not).
  catalog = import ../../modules/ai/key-catalog.generated.nix;
  keyArgs = map (entry: "${config.sops.secrets.${entry.name}.path}:${entry.envVar}") catalog.keys;

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
in
{
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
      EnvironmentVariables = litellmEnv;
      StandardOutPath = "${config.nucleus.logging.systemLogDir}/litellm/stdout.log";
      StandardErrorPath = "${config.nucleus.logging.systemLogDir}/litellm/stderr.log";
    };
  };

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
      # The catalog is the single source of truth for these values.  OLLAMA_HOST
      # is excluded so the daemon binds to the default port (11434).  OLLAMA_HOST
      # is set by the gui-env LaunchAgent for CLI clients.
      EnvironmentVariables = ollamaEnv;
      StandardOutPath = "${config.nucleus.logging.systemLogDir}/ollama/stdout.log";
      StandardErrorPath = "${config.nucleus.logging.systemLogDir}/ollama/stderr.log";
    };
  };
}
