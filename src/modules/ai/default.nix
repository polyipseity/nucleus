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
# Instead, apply.sh and apply.ps1 call scripts/AI-sync.sh / Invoke-AISync as
# the final step of every apply run.  Pass --skip-AI-sync (-SkipAISync on
# Windows) to suppress the sync step in CI or on low-bandwidth connections.
#
# Model manifest: src/modules/ai/models.json
#   macbook: devstral:24b, magistral:24b  — re-test tool-calling curl on macbook
#                                             after model swap before relying on tools
#   nixos:   qwen3:8b               — tool-calling NOT yet curl-tested on nixos;
#                                     verify with the same curl test before relying
#                                     on tool-calling on the nixos host.
#   windows: qwen3:8b               — same as nixos; tool-calling NOT yet
#                                     curl-tested on windows.
{
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
      # system-level services.ollama unit (hosts/nixos/ai.nix); the package
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
      OLLAMA_HOST = "127.0.0.1:11434";
    };
  }

  # macOS-only: user launchd agent for the Ollama inference server.
  # On NixOS the equivalent is the system-level services.ollama unit in
  # hosts/nixos/ai.nix; no Home Manager unit is needed there.
  # The launchd option is Darwin-only in Home Manager so the entire block
  # must be guarded to avoid "unknown option" errors on Linux.
  (lib.mkIf pkgs.stdenv.isDarwin {
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
          OLLAMA_NUM_CTX = "32768";
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
