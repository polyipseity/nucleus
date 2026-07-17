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
  "agentHostShellConfig"
  "agentsSkills"
  "agentsSymlink"
  "cloudDrivesSetup"
  "configureObsidianSettings"
  "configurePicardSettings"
  "configureQtPassSettings"
  "devReposProvision"
  "ensureCustomProvisionSymlinkTargets"
  "finalizeCustomProvisionSymlinks"
  "git-identity"
  "gitIgnoreAssemble"
  "gpg-import"
  "installBunPackages"
  "installPwshScriptAnalyzer"
  "installUvTools"
  "installZshCompletions"
  "prepareCustomProvisionSymlinks"
  "provisionDevDirectory"
  "ssh-key-adopt"
  "syncClawHubSkills"
  "verifySecretDecryption"
  "vsCodeExtensionBridge"
  "vsCodeSymlinks"
  "vsCodeWorkspaceTrust"
  "waitForSopsSecrets"
  "wallpaperProvision"
]
