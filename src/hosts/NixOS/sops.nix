# NixOS/sops.nix — NixOS-specific SOPS overrides.
# Shared POSIX SOPS defaults live in ../../modules/posix-sops.nix.
#
# LiteLLM service runs as the dedicated `litellm` user (declared in
# hosts/NixOS/ai.nix), so the AI API key secrets must be owned by it.
{ ... }:
let
    # Data-driven: read the env catalog to determine which SOPS secrets to
    # declare.  The catalog is emitted as a Nix expression by ensure_env_catalog
    # so it is importable under pure evaluation.
    catalog = import ../../modules/ai/env-catalog.generated.nix;
in
{
  # System-level SOPS secrets used by the LiteLLM systemd service
  # (hosts/NixOS/ai.nix).  sops-nix writes each secret as a plain file to
  # /run/secrets/<name> by default.
  # OWNER: the systemd service runs as `litellm` (not root and not the user),
  # so the secret files must be owned by and readable by that user.
  sops.secrets = builtins.listToAttrs (
    map (entry: {
      name = entry.name;
      value = {
        sopsFile = ../../secrets/system.yml;
        owner = "litellm";
        mode = "0400";
      };
    }) catalog.keys
  )
  // {
    # Redis password for LiteLLM coordination + response cache.
    # Not in the env_key_* catalog (naming convention differs).
    env_redis_password = {
      sopsFile = ../../secrets/system.yml;
      owner = "litellm";
      mode = "0400";
    };
  };
}
