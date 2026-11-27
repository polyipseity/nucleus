# src/modules/lib/activation-dag.nix - activation entry names shared by every
# POSIX Home Manager host. Host modules append their own entries after importing
# this list instead of duplicating it, so a new shared entry lands here once.
#
#   sharedActivationDeps = (import ../lib/activation-dag.nix) ++ [ "entry" ];
[
  "installAgentSkills"
  "symlinkAgentConfig"
  "symlinkCursorConfig"
  "cloudDrivesSetup"
  "mergeObsidianJson"
  "mergePicardIni"
  "mergeQtpassIni"
  "provisionDevRepos"
  "ensureSymlinkTargets"
  "finalizeSymlinks"
  "materializeUserSecrets"
  "installBunPackages"
  "installPwshScriptAnalyzer"
  "installUvTools"
  "installZshCompletions"
  "prepareSymlinks"
  "ensureDevDirectory"
  "syncClawhubSkills"
  "verifySecretDecryption"
  "symlinkVscodeExtensions"
  "symlinkVscodeConfig"
  "trustVscodeWorkspace"
  "trustPiProject"
  "provisionWallpapers"
]
