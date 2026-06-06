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
# Usage:
#   displayHostManualInstructionDeps = (import ../lib/activation-dag.nix) ++ [
#     "hostSpecificEntry"
#   ];
[
  "agentsSkills"
  "agentsSymlink"
  "configureObsidianSettings"
  "ensureCustomProvisionSymlinkTargets"
  "finalizeCustomProvisionSymlinks"
  "gitIdentityFromSops"
  "gitIgnoreAssemble"
  "gpgImport"
  "installBunPackages"
  "installPwshScriptAnalyzer"
  "installUvTools"
  "prepareCustomProvisionSymlinks"
  "provisionDevDirectory"
  "sshKeyAdopt"
  "syncClawHubSkills"
  "verifySecretDecryption"
  "vsCodeExtensionBridge"
  "vsCodeSymlinks"
  "vsCodeWorkspaceTrust"
  "waitForSopsSecrets"
  "wallpaperProvision"
]
