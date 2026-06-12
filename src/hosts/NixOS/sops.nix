# NixOS/sops.nix — NixOS-specific SOPS overrides.
# Shared POSIX SOPS defaults live in ../../modules/posix-sops.nix.
{
  config,
  lib,
  pkgs,
  username,
  ...
}:
{
  # System-level SOPS secrets used by the LiteLLM systemd service
  # (hosts/NixOS/ai.nix).  sops-nix writes each secret as a plain file to
  # /run/secrets/<name> by default.
  # OWNER: the systemd service runs as `username` (not root), so the secret
  # files must be owned by and readable by that user.
  sops.secrets."ai_openrouter_api_key" = {
    sopsFile = ../../secrets/system.yml;
    owner = username;
    mode = "0400";
  };

  sops.secrets."ai_opencode_api_key" = {
    sopsFile = ../../secrets/system.yml;
    owner = username;
    mode = "0400";
  };
}
