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
  litellmConfig = "${userHome}/.config/nucleus/litellm-config.yml";
  envVars = import ../../modules/lib/env-vars.nix {
    inherit
      config
      pkgs
      lib
      username
      ;
  };
  resolveValue = name: envVars.resolveValue name "macOS";
  # Daemon env vars from the centralized catalog.
  # Provides NIX_SSL_CERT_FILE (HTTPS) and NUCLEUS_HOST (host identity).
  litellmEnv = lib.filterAttrs (_name: value: value != null) {
    NIX_SSL_CERT_FILE = resolveValue "NIX_SSL_CERT_FILE";
    NUCLEUS_HOST = resolveValue "NUCLEUS_HOST";
  };
  # Ollama daemon env vars: OLLAMA_* runtime tunables excluding OLLAMA_HOST.
  # OLLAMA_HOST is excluded because the ollama server must bind to the default
  # port (11434), not the LiteLLM proxy port (4000).  OLLAMA_HOST is set by
  # the gui-env-system LaunchAgent for CLI clients that should route through the
  # proxy.
  ollamaEnv =
    litellmEnv
    // lib.filterAttrs (_name: value: value != null) {
      OLLAMA_FLASH_ATTENTION = resolveValue "OLLAMA_FLASH_ATTENTION";
      OLLAMA_CONTEXT_LENGTH = resolveValue "OLLAMA_CONTEXT_LENGTH";
      OLLAMA_KV_CACHE_TYPE = resolveValue "OLLAMA_KV_CACHE_TYPE";
    };
in
{
  launchd.daemons."local.litellm" = {
    serviceConfig = {
      # macOS 26+ SIP blocks unsigned Nix store binaries for system daemons
      # with non-root UserName (EX_CONFIG 78). /bin/sh is Apple-signed and
      # passes SIP gate. See .agents/instructions/macos-launchd-sip.instructions.md.
      ProgramArguments = [
        "/bin/sh"
        "-c"
        "exec ${pkgs.writeShellScript "litellm-daemon" ''
          _keyfile_oru="${config.sops.secrets."ai_openrouter_api_key".path}"
          if [ -f "$_keyfile_oru" ]; then
            export OPENROUTER_API_KEY="$(cat "$_keyfile_oru")"
          fi
          _keyfile_oc_go="${config.sops.secrets."ai_opencode_go_api_key".path}"
          if [ -f "$_keyfile_oc_go" ]; then
            export OPENCODE_GO_API_KEY="$(cat "$_keyfile_oc_go")"
          fi
          _keyfile_oc_zen="${config.sops.secrets."ai_opencode_zen_api_key".path}"
          if [ -f "$_keyfile_oc_zen" ]; then
            export OPENCODE_ZEN_API_KEY="$(cat "$_keyfile_oc_zen")"
          fi
          exec ${pkgs.litellm}/bin/litellm \
            --config ${litellmConfig} \
            --port 4000 \
            --host 127.0.0.1 \
            --drop_params
        ''}"
      ];
      KeepAlive = true;
      RunAtLoad = true;
      UserName = username;
      EnvironmentVariables = litellmEnv;
      StandardOutPath = "${config.nucleus.logging.systemLogDir}/litellm/stdout.log";
      StandardErrorPath = "${config.nucleus.logging.systemLogDir}/litellm/stderr.log";
    };
  };

  launchd.daemons."local.ollama" = {
    serviceConfig = {
      # macOS 26+ SIP blocks unsigned Nix store binaries for system daemons
      # with non-root UserName (EX_CONFIG 78). /bin/sh is Apple-signed and
      # passes SIP gate. See .agents/instructions/macos-launchd-sip.instructions.md.
      ProgramArguments = [
        "/bin/sh"
        "-c"
        "exec ${pkgs.ollama}/bin/ollama serve"
      ];
      KeepAlive = true;
      RunAtLoad = true;
      UserName = username;
      # Source: src/modules/lib/env-vars.nix (OLLAMA_* entries).
      # The catalog is the single source of truth for these values.  OLLAMA_HOST
      # is excluded so the daemon binds to the default port (11434).  OLLAMA_HOST
      # is set by the gui-env-system LaunchAgent for CLI clients.
      EnvironmentVariables = ollamaEnv;
      StandardOutPath = "${config.nucleus.logging.systemLogDir}/ollama/stdout.log";
      StandardErrorPath = "${config.nucleus.logging.systemLogDir}/ollama/stderr.log";
    };
  };
}
