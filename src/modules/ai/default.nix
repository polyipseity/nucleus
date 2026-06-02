# modules/ai/default.nix — Local AI inference baseline for all POSIX hosts.
#
# Provides:
#   • pkgs.ollama — inference server and CLI (GPU-enabled where host runtime supports it)
#   • pkgs.oterm  — terminal chat client for interactive LLM sessions
#   • OLLAMA_HOST session variable that binds client tools to the loopback address
#   • macOS: launchd user agent that keeps the Ollama server running persistently
#
# Model management is NOT part of Home Manager activation — model pulls are
# 2–20 GB and would make `nix run .#apply` hang indefinitely if run inline.
# Instead, apply.sh and apply.ps1 call scripts/ai-sync.sh / Invoke-AISync as
# the final step of every apply run.  Pass --skip-ai-sync (-SkipAISync on
# Windows) to suppress the sync step in CI or on low-bandwidth connections.
#
# Model manifest: src/modules/ai/models.json
#   MacBook: devstral-small-2:24b, magistral:24b  — re-test tool-calling curl on MacBook
#                                             after model swap before relying on tools
#            qwen2.5:1.5b            — small utility model; ~1 GB; runs on any modern PC;
#                                      no tool-calling (not reliable at 1.5B)
#   NixOS:   qwen2.5:1.5b            — same utility model; no tool-calling
#            qwen3:8b               — tool-calling NOT yet curl-tested on NixOS;
#                                     verify with the same curl test before relying
#                                     on tool-calling on the NixOS host.
#   Windows: qwen2.5:1.5b            — same utility model; no tool-calling
#            qwen3:8b               — same as NixOS; tool-calling NOT yet
#                                     curl-tested on Windows.
{
  config,
  lib,
  nixpkgs,
  pkgs,
  ...
}:
let
  # Only Apple Silicon macOS currently needs an opt-in permissive import for
  # oterm's dependency chain. Keeping the import lazy and isolated preserves
  # strict evaluation for the rest of the package set.
  appleSiliconDarwin = pkgs.stdenv.isDarwin && pkgs.stdenv.hostPlatform.system == "aarch64-darwin";

  otermPkg =
    if appleSiliconDarwin then
      let
        permissivePkgs = import nixpkgs {
          inherit (pkgs.stdenv.hostPlatform) system;
          config.allowUnfree = true;
          config.allowUnsupportedSystem = true;
        };
      in
      permissivePkgs.oterm
    else
      pkgs.oterm;
in
lib.mkMerge [
  {
    home.packages = [
      # Inference server and CLI.  On NixOS the server is managed by the
      # system-level services.ollama unit (hosts/NixOS/ai.nix); the package
      # here provides the `ollama` CLI for user-facing pulls, queries, and
      # model management.  On macOS the launchd agent below starts the server.
      pkgs.ollama
      # Terminal-native chat frontend for interactive sessions.  Speaks the
      # Ollama HTTP API directly; works against any running Ollama server.
      otermPkg
    ];

    # Bind all Ollama client tools (oterm, ollama pull/run/list) to the
    # loopback address.  Explicit declaration documents the security intent
    # and guards against upstream default changes (Ollama defaults vary by
    # version).
    home.sessionVariables = {
      # Point clients at the LiteLLM proxy (127.0.0.1:4000) instead of Ollama
      # directly so that oterm, ollama run, and any other OpenAI-compatible
      # client gets unified routing to both local and remote models.  Sync
      # scripts override this back to :11434 for direct model management.
      OLLAMA_HOST = "127.0.0.1:4000";
    };
  }

  # macOS-only: user launchd agent for the Ollama inference server.
  # On NixOS the equivalent is the system-level services.ollama unit in
  # hosts/NixOS/ai.nix; no Home Manager unit is needed there.
  # The launchd option is Darwin-only in Home Manager so the entire block
  # must be guarded to avoid "unknown option" errors on Linux.
  (lib.mkIf pkgs.stdenv.isDarwin {
    launchd.agents."litellm" = {
      enable = true;
      config = {
        Label = "local.litellm";
        # Wrapper script reads the SOPS-decrypted OpenRouter key file
        # (KEY=VALUE format) and exports it before launching LiteLLM because
        # launchd EnvironmentVariables does not support file sourcing.
        ProgramArguments = [
          "/bin/sh"
          "-c"
          ''
            if [ -f "${config.sops.secrets."ai_openrouter_api_key".path}" ]; then
              export OPENROUTER_API_KEY="$(cat "${config.sops.secrets."ai_openrouter_api_key".path}")"
            fi
            exec ${pkgs.litellm}/bin/litellm \
              --config ${pkgs.writeText "litellm-config.yml" (builtins.readFile ./litellm-config.yml)} \
              --port 4000 \
              --host 127.0.0.1 \
              --drop_params
          ''
        ];
        KeepAlive = true;
        RunAtLoad = true;
        # Suppress request logs; LiteLLM is verbose per-request.
        StandardOutPath = "/dev/null";
        StandardErrorPath = "/dev/null";
      };
    };

    launchd.agents."ollama" = {
      enable = true;
      config = {
        Label = "local.ollama";
        ProgramArguments = [
          "${pkgs.ollama}/bin/ollama"
          "serve"
        ];
        # Bind the server to loopback so the unauthenticated Ollama REST API
        # is never reachable from LAN peers.  0.0.0.0 binding (the historic
        # Ollama default on some versions) would expose model inference to
        # anyone on the local network without any authentication requirement.
        EnvironmentVariables = {
          # Compress the KV cache with 4-bit quantisation to halve the
          # KV-cache RAM footprint so larger context windows fit in unified
          # memory without evicting model weights from the metal buffer pool.
          OLLAMA_FLASH_ATTENTION = "1";
          OLLAMA_HOST = "127.0.0.1:11434";
          # q4_0 compression paired with flash attention achieves a good
          # quality/memory tradeoff; switch to f16 if accuracy regressions
          # appear on specific models.
          OLLAMA_KV_CACHE_TYPE = "q4_0";
          # Set a 32 k token default context window so models that default to
          # 2 k or 4 k do not silently truncate long conversations.  Individual
          # `ollama run` calls can still override with --ctx=N.
          # Source: Ollama environment variable reference.
          # https://docs.ollama.com/faq#how-can-i-specify-the-context-window-size
          OLLAMA_CONTEXT_LENGTH = "32768";
        };
        # Restart the server automatically after crashes or macOS restarts
        # so the inference endpoint is always available without manual
        # intervention.
        KeepAlive = true;
        RunAtLoad = true;
        # Suppress per-request log lines; Ollama emits one entry per
        # inference request which floods the system log under normal use.
        # This suppression is intentional: (1) request logs are verbose and
        # not actionable for routine operator review, (2) this comment
        # explains why, and (3) startup failures surface via launchd
        # exit-status tracking — check with:
        #   launchctl list | grep local.ollama
        StandardOutPath = "/dev/null";
        StandardErrorPath = "/dev/null";
      };
    };
  })
]
