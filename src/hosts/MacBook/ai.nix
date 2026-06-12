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
  pkgs,
  username,
  ...
}:
let
  userHome = "/Users/${username}";
  litellmConfig = "${userHome}/.config/nucleus/litellm-config.yml";
in
{
  launchd.daemons."local.litellm" = {
    command = pkgs.writeShellScript "litellm-daemon" ''
      _keyfile_oru="${config.sops.secrets."ai_openrouter_api_key".path}"
      if [ -f "$_keyfile_oru" ]; then
        export OPENROUTER_API_KEY="$(cat "$_keyfile_oru")"
      fi
      _keyfile_oc="${config.sops.secrets."ai_opencode_api_key".path}"
      if [ -f "$_keyfile_oc" ]; then
        export OPENCODE_GO_API_KEY="$(cat "$_keyfile_oc")"
      fi
      exec ${pkgs.litellm}/bin/litellm \
        --config ${litellmConfig} \
        --port 4000 \
        --host 127.0.0.1 \
        --drop_params
    '';
    serviceConfig = {
      KeepAlive = true;
      RunAtLoad = true;
      UserName = username;
      StandardOutPath = "/dev/null";
      StandardErrorPath = "/Users/Shared/LiteLLM/log/proxy.log";
    };
  };

  launchd.daemons."local.ollama" = {
    command = "${pkgs.ollama}/bin/ollama serve";
    serviceConfig = {
      KeepAlive = true;
      RunAtLoad = true;
      UserName = username;
      EnvironmentVariables = {
        OLLAMA_FLASH_ATTENTION = "1";
        OLLAMA_HOST = "127.0.0.1:11434";
        OLLAMA_KV_CACHE_TYPE = "q4_0";
        OLLAMA_CONTEXT_LENGTH = "32768";
      };
      StandardOutPath = "/dev/null";
      StandardErrorPath = "/dev/null";
    };
  };
}
