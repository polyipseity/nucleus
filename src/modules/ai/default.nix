# modules/ai/default.nix — Local AI inference baseline for all POSIX hosts.
#
# Provides:
#   • pkgs.ollama — inference server and CLI (GPU-enabled where host runtime supports it)
#   • pkgs.oterm  — terminal chat client for interactive LLM sessions
#   • OLLAMA_HOST session variable that binds client tools to the loopback address
#
# Model management is NOT part of Home Manager activation — model pulls are
# 2–20 GB and would make `nix run .#apply` hang indefinitely if run inline.
# Instead, apply.sh and apply.ps1 call scripts/ai-sync.sh / Invoke-AISync as
# the final step of every apply run.  Pass --no-ai-sync (-NoAISync on Windows)
# to suppress the sync step in CI or on low-bandwidth connections.
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
  # Read endpoint addresses from the canonical service registry so that
  # client-side defaults stay in sync with the daemon bind ports defined
  # in host-level configuration.
  servicesJSON = builtins.fromJSON (builtins.readFile ../services.json);
  litellmEndpoint = servicesJSON.litellm.network.default;

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
      # Inference server and CLI.  On NixOS and macOS the server is managed
      # by system-level services (hosts/NixOS/ai.nix, hosts/MacBook/ai.nix);
      # the package here provides the `ollama` CLI for user-facing pulls,
      # queries, and model management.
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
      # Point clients at the LiteLLM proxy instead of Ollama directly so
      # that oterm, ollama run, and any other OpenAI-compatible client gets
      # unified routing to both local and remote models.  Sync scripts
      # override this back to :11434 for direct model management.
      OLLAMA_HOST = "${litellmEndpoint.host}:${toString litellmEndpoint.port}";
    };
  }

]
