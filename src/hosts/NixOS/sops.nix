# NixOS/sops.nix — NixOS-specific SOPS overrides.
# Shared POSIX SOPS defaults live in ../../modules/posix-sops.nix.
{ ... }:
{
  # System-level SOPS secret for the OpenRouter API key used by the LiteLLM
  # systemd service (hosts/NixOS/ai.nix).  The environment file is read by
  # systemd's EnvironmentFile directive, so the file content must be plain
  # KEY=VALUE lines (sops-nix writes in this format by default).
  sops.secrets."ai_openrouter_api_key" = {
    sopsFile = ../../secrets/system.yml;
    # No explicit path — sops-nix writes to its default tmpfs path
    # (/run/secrets/ai_openrouter_api_key) which systemd can access via
    # EnvironmentFile.
  };
}
