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
  };
}
