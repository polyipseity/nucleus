# modules/ai/default.nix — Local AI inference baseline for all POSIX hosts.
#
# Provides:
#   • pkgs.ollama — inference server and CLI (CPU-only; no GPU driver deps)
#   • pkgs.oterm  — terminal chat client for interactive LLM sessions
#   • OLLAMA_HOST session variable that binds client tools to the loopback address
#   • macOS: launchd user agent that keeps the Ollama server running persistently
#
# Model management is intentionally NOT part of activation — model pulls are
# 2–20 GB and would make `nix run .#apply` hang indefinitely.  Use
# scripts/ai-sync.sh to synchronise the declared model manifest with the
# locally installed set after provisioning.
{ lib, pkgs, ... }:
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
      pkgs.oterm
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
        ProgramArguments = [ "${pkgs.ollama}/bin/ollama" "serve" ];
        # Bind the server to loopback so the unauthenticated Ollama REST API
        # is never reachable from LAN peers.  0.0.0.0 binding (the historic
        # Ollama default on some versions) would expose model inference to
        # anyone on the local network without any authentication requirement.
        EnvironmentVariables = {
          OLLAMA_HOST = "127.0.0.1:11434";
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
