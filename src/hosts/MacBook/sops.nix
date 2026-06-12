# MacBook/sops.nix — MacBook-specific SOPS overrides.
# Shared POSIX SOPS defaults live in ../../modules/posix-sops.nix.
{ ... }: {
  # System-level SOPS secrets used by the system-wide LiteLLM launchd daemon
  # (hosts/MacBook/ai.nix).  sops-nix writes each secret as a plain file to
  # /run/secrets/<name> by default.
  sops.secrets."ai_openrouter_api_key" = {
    sopsFile = ../../secrets/system.yml;
  };

  sops.secrets."ai_opencode_api_key" = {
    sopsFile = ../../secrets/system.yml;
  };
}
