# hosts/NixOS/ai.nix - NixOS system-level AI inference stack.
#
# LiteLLM routes client requests to remote providers with order-based failover.
# modules/ai.nix provides the CLI and the OLLAMA_HOST session variable.
{
  config,
  lib,
  pkgs,
  username,
  ...
}:
let
  litellmConfig = "${config.users.users.${username}.home}/.local/share/nucleus/litellm-config.yml";
  litellmLogConfig = "${
    config.users.users.${username}.home
  }/.local/share/nucleus/logging_config.json";
  litellmDaemon = pkgs.writeNucleusShellApplication {
    name = "litellm-daemon";
    runtimeInputs = [ pkgs.litellm ];
    scriptName = "src/scripts/services/litellm-daemon";
  };
  servicesJSON = builtins.fromJSON (builtins.readFile ../../modules/services.json);
  ollamaCfg = servicesJSON.ollama.network.default;
  secrets = builtins.fromJSON (builtins.readFile ../../modules/env/env-secrets.json);
  envLib = import ../../modules/lib/env-secrets.nix {
    inherit
      config
      pkgs
      lib
      username
      ;
    hostName = "NixOS";
  };
  secretArgs = envLib.mkSecretArgsForConsumer {
    inherit config secrets;
    consumer = "litellm";
  };
in
{
  # nixpkgs has no services.litellm module, so the service is defined here.
  # ExecStart runs a shell wrapper that exports SOPS-decrypted API keys as
  # environment variables: systemd's EnvironmentFile wants KEY=VALUE, sops-nix
  # writes the raw value.
  systemd.services.litellm = {
    description = "LiteLLM AI Gateway Proxy";
    wantedBy = [ "multi-user.target" ];
    after = [
      "network.target"
      "nucleus-redis.service"
    ];
    wants = [ "nucleus-redis.service" ];
    path = [ pkgs.litellm ];
    environment = {
      LITELLM_LOG_CONFIG = litellmLogConfig;
      PYTHONPATH = "${config.users.users.${username}.home}/.local/share/nucleus";
    };
    serviceConfig = {
      Type = "simple";
      ExecStart = "${litellmDaemon}/bin/nucleus-litellm-daemon '${litellmConfig}' '0' ${
        lib.concatStringsSep " " (map (arg: "'${arg}'") secretArgs)
      }";
      Restart = "always";
      User = "litellm";
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
    host = ollamaCfg.host;
    port = ollamaCfg.port;
    # Enable GPU inference explicitly for this host class.  The repository's
    # planning assumption for nixos/windows is a 6 GB discrete GPU tier, and
    # Ollama should use a CUDA-capable package on compatible NVIDIA setups.
    package = pkgs.ollama-cuda;

    # 4-bit KV cache and flash attention halve the memory cost; the 32 k
    # default context stops models that default to 2 k or 4 k from silently
    # truncating long conversations.
    # https://github.com/ollama/ollama/blob/main/docs/faq.md
    # https://github.com/ollama/ollama/blob/main/envconfig/config.go
    environmentVariables =
      let
        envVars' = import ../../modules/lib/env-secrets.nix {
          inherit
            config
            pkgs
            lib
            username
            ;
          hostName = "NixOS";
        };
        resolveValue' = name: envVars'.resolveValue name "NixOS";
      in
      lib.filterAttrs (_name: value: value != null) {
        OLLAMA_FLASH_ATTENTION = resolveValue' "OLLAMA_FLASH_ATTENTION";
        OLLAMA_CONTEXT_LENGTH = resolveValue' "OLLAMA_CONTEXT_LENGTH";
        OLLAMA_KV_CACHE_TYPE = resolveValue' "OLLAMA_KV_CACHE_TYPE";
      };
  };

  # Redis coordination and response caching for LiteLLM lives in the shared
  # src/modules/redis.nix as services.redis.servers.nucleus.

  # Cap Ollama at 16 GB RSS so an oversized model pull or runaway session cannot
  # OOM-kill unrelated services. macOS has no launchd equivalent; the loopback
  # bind and the model manifest are the guard there.
  # https://man7.org/linux/man-pages/man5/systemd.resource-control.5.html
  systemd.services.ollama.serviceConfig.MemoryMax = "16G";

  # System user for privilege separation: non-root, own secrets only.
  users.users.litellm = {
    isSystemUser = true;
    group = "litellm";
    description = "LiteLLM AI gateway service user";
  };
  users.groups.litellm = { };

  # A catalog with AI keys but no resolved secretArgs starts LiteLLM with no
  # KEYFILE:ENVVAR pairs and every `default` request fails with
  # "Missing credentials". Report the keys the SOPS file is missing.
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
}
