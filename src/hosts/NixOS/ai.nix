# hosts/NixOS/ai.nix — NixOS system-level AI inference stack.
#
# Provides:
#   • Ollama — local LLM inference server on 127.0.0.1:11434
#   • LiteLLM — AI gateway proxy on 127.0.0.1:4000 that routes client requests
#     to Ollama and OpenRouter.
#
# The Home Manager module modules/ai/default.nix provides the ollama CLI binary,
# OLLAMA_HOST session variable, and the oterm client on all POSIX hosts
# including this one.
{ config, pkgs, ... }:
let
  litellmConfig = pkgs.writeText "litellm-config.yml" (
    builtins.readFile ../../modules/ai/litellm-config.yml
  );
in
{
  # LiteLLM AI gateway — systemd service on 127.0.0.1:4000.
  # Since nixpkgs has no services.litellm module yet, we define the service
  # manually.  ExecStart uses a shell wrapper that reads the SOPS-decrypted
  # OpenRouter key and exports it before launching LiteLLM — systemd's
  # EnvironmentFile expects KEY=VALUE format, but sops-nix writes the raw value.
  systemd.services.litellm = {
    description = "LiteLLM AI Gateway Proxy";
    wantedBy = [ "multi-user.target" ];
    after = [ "network.target" ];
    path = [ pkgs.litellm ];
    serviceConfig = {
      Type = "simple";
      ExecStart = "${pkgs.writeShellScript "litellm-wrapper" ''
        _keyfile="${config.sops.secrets."ai_openrouter_api_key".path}"
        if [ -f "$_keyfile" ]; then
          export OPENROUTER_API_KEY="$(cat "$_keyfile")"
        fi
        _mkeyfile="${config.sops.secrets."litellm_master_key".path}"
        if [ -f "$_mkeyfile" ]; then
          export LITELLM_MASTER_KEY="$(cat "$_mkeyfile")"
        fi
        exec ${pkgs.litellm}/bin/litellm \
          --config ${litellmConfig} \
          --port 4000 \
          --host 127.0.0.1 \
          --drop_params
      ''}";
      Restart = "on-failure";
      RestartSec = 5;
      # Protect against resource exhaustion and information leaks.
      PrivateTmp = true;
      NoNewPrivileges = true;
      MemoryMax = "2G";
    };
  };

  services.ollama = {
    enable = true;
    # Bind to loopback so the unauthenticated Ollama REST API is only
    # reachable from this machine.  Binding to 0.0.0.0 (the upstream default
    # on some versions) would expose the API to all LAN peers without any
    # authentication requirement.
    #
    host = "127.0.0.1";
    port = 11434;
    # Enable GPU inference explicitly for this host class.  The repository's
    # planning assumption for nixos/windows is a 6 GB discrete GPU tier, and
    # Ollama should use a CUDA-capable package on compatible NVIDIA setups.
    package = pkgs.ollama-cuda;

    # Compress the KV cache with 4-bit quantisation to halve KV-cache RAM
    # footprint, enable flash attention to reduce attention memory overhead,
    # and set a 32 k token default context window so models that default to
    # 2 k or 4 k do not silently truncate long conversations.
    # Source: Ollama runtime environment-variable references.
    # https://github.com/ollama/ollama/blob/main/docs/faq.md
    # https://github.com/ollama/ollama/blob/main/envconfig/config.go
    environmentVariables = {
      OLLAMA_FLASH_ATTENTION = "1";
      # Source: Ollama context-window environment variable.
      # https://docs.ollama.com/faq#how-can-i-specify-the-context-window-size
      OLLAMA_CONTEXT_LENGTH = "32768";
      OLLAMA_KV_CACHE_TYPE = "q4_0";
    };
  };

  # Cap the Ollama systemd service at 16 GB RSS so an oversized model pull
  # or runaway inference session cannot exhaust RAM and cause OOM kills of
  # unrelated system services.  macOS has no equivalent RLIMIT-based RAM cap
  # mechanism via launchd; the loopback-only binding and model manifest are
  # the macOS memory guard instead.
  # Source: systemd resource-control MemoryMax semantics.
  # https://man7.org/linux/man-pages/man5/systemd.resource-control.5.html
  systemd.services.ollama.serviceConfig.MemoryMax = "16G";
}
