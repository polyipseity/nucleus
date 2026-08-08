# src/modules/lib/activation-dag.nix — Shared activation DAG dependencies.
#
# Home Manager activation entry names that are defined in shared modules
# (agents.nix, secrets.nix, home.nix, etc.) and referenced by every POSIX
# Home Manager host (macOS, NixOS, Linux).
#
# Host-specific modules append their own entries after importing this list
# instead of duplicating the shared set.  When adding a new shared activation
# entry, add its name here so all hosts inherit it automatically.
#
# Usage in host configs:
#   sharedActivationDeps = (import ../lib/activation-dag.nix) ++ [
#     "hostSpecificEntry"
#   ];
[
  "agent-host-shell-config"
  "install-agent-skills"
  "symlink-agent-config"
  "symlink-cursor-config"
  "cloud-drives-setup"
  "merge-obsidian-json"
  "merge-picard-ini"
  "merge-qtpass-ini"
  "provision-dev-repos"
  "ensure-symlink-targets"
  "finalize-symlinks"
  "materialize-user-secrets"
  "install-bun-packages"
  "install-pwsh-script-analyzer"
  "install-uv-tools"
  "install-zsh-completions"
  "prepare-symlinks"
  "ensure-dev-directory"
  "sync-clawhub-skills"
  "verify-secret-decryption"
  "symlink-vscode-extensions"
  "symlink-vscode-config"
  "trust-vscode-workspace"
  "provision-wallpapers"
]
