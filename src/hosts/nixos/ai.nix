# hosts/nixos/ai.nix — NixOS system-level Ollama inference service.
#
# Enables Ollama as a systemd system service so the inference server starts
# at boot and survives user session boundaries (required for headless and
# remote-desktop use cases).  The Home Manager module modules/ai/default.nix
# provides the ollama CLI binary and OLLAMA_HOST session variable on all
# POSIX hosts including this one.
{ ... }:
{
  services.ollama = {
    enable = true;
    # Bind to loopback so the unauthenticated Ollama REST API is only
    # reachable from this machine.  Binding to 0.0.0.0 (the upstream default
    # on some versions) would expose the API to all LAN peers without any
    # authentication requirement.
    #
    # Note: if evaluation fails with "unknown option services.ollama.listenAddress",
    # the pinned nixpkgs uses the older split interface; replace with:
    #   host = "127.0.0.1";
    #   port = 11434;
    listenAddress = "127.0.0.1:11434";
    # GPU acceleration intentionally unset to use the safe CPU-only default.
    # Enable NVIDIA or AMD acceleration by setting:
    #   acceleration = "cuda";  # NVIDIA
    #   acceleration = "rocm";  # AMD (also requires compatible hardware modules)

    # Compress the KV cache with 4-bit quantisation to halve KV-cache RAM
    # footprint, enable flash attention to reduce attention memory overhead,
    # and set a 32 k token default context window so models that default to
    # 2 k or 4 k do not silently truncate long conversations.
    environmentVariables = {
      OLLAMA_FLASH_ATTENTION = "1";
      OLLAMA_KV_CACHE_TYPE = "q4_0";
      OLLAMA_NUM_CTX = "32768";
    };
  };

  # Cap the Ollama systemd service at 16 GB RSS so an oversized model pull
  # or runaway inference session cannot exhaust RAM and cause OOM kills of
  # unrelated system services.  macOS has no equivalent RLIMIT-based RAM cap
  # mechanism via launchd; the loopback-only binding and model manifest are
  # the macOS memory guard instead.
  systemd.services.ollama.serviceConfig.MemoryMax = "16G";
}
