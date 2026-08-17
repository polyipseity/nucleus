# NixOS/sops.nix — NixOS-specific SOPS overrides.
# Shared POSIX SOPS defaults live in ../../modules/posix-sops.nix.
#
# LiteLLM service runs as the dedicated `litellm` user (declared in
# hosts/NixOS/ai.nix), so the AI API key secrets must be owned by it.
{ ... }: {
  # System-level SOPS secrets used by the LiteLLM systemd service
  # (hosts/NixOS/ai.nix).  sops-nix writes each secret as a plain file to
  # /run/secrets/<name> by default.
  # OWNER: the systemd service runs as `litellm` (not root and not the user),
  # so the secret files must be owned by and readable by that user.
  sops.secrets."ai_openrouter_api_key" = {
    sopsFile = ../../secrets/system.yml;
    owner = "litellm";
    mode = "0400";
  };

  sops.secrets."ai_opencode_go_api_key" = {
    sopsFile = ../../secrets/system.yml;
    owner = "litellm";
    mode = "0400";
  };

  sops.secrets."ai_opencode_zen_api_key" = {
    sopsFile = ../../secrets/system.yml;
    owner = "litellm";
    mode = "0400";
  };

  sops.secrets."ai_command_code_api_key" = {
    sopsFile = ../../secrets/system.yml;
    owner = "litellm";
    mode = "0400";
  };
}
