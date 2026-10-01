# src/modules/lib/activation-dag.nix - activation entry names shared by every
# POSIX Home Manager host. Host modules append their own entries after importing
# this list instead of duplicating it, so a new shared entry lands here once.
#
#   sharedActivationDeps = (import ../lib/activation-dag.nix) ++ [ "entry" ];
[
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
  "trust-pi-project"
  "provision-wallpapers"
]
