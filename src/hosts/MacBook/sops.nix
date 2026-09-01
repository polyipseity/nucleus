# MacBook/sops.nix — MacBook-specific SOPS overrides.
# Shared POSIX SOPS defaults live in ../../modules/posix-sops.nix.
{ username, ... }:
let
    # Data-driven: read the env catalog to determine which SOPS secrets to
    # declare.  The catalog is emitted as a Nix expression by ensure_env_catalog
    # so it is importable under pure evaluation.
    catalog = import ../../modules/ai/env-catalog.generated.nix;
in
{
  # System-level SOPS secrets used by the system-wide LiteLLM launchd daemon
  # (hosts/MacBook/ai.nix).  sops-nix writes each secret as a plain file to
  # /run/secrets/<name> by default.
  # OWNER: the launchd daemon runs as `username` (not root), so the secret
  # files must be owned by and readable by that user.
  sops.secrets = builtins.listToAttrs (
    map (entry: {
      name = entry.name;
      value = {
        sopsFile = ../../secrets/system.yml;
        owner = username;
        mode = "0400";
      };
    }) catalog.keys
  );
}
