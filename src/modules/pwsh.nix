# PowerShell profile for POSIX hosts.
{
  config,
  lib,
  pkgs,
  username,
  ...
}:
let
  managedPaths = import ./lib/managed-paths.nix { inherit pkgs; };
  envVars = import ./lib/env-catalog.nix {
    inherit
      config
      pkgs
      lib
      username
      ;
  };

  agentEnv = import ./agent-env-vars.nix;

  lockfile = builtins.fromJSON (builtins.readFile ../lockfiles/lockfile.json);
  pwshAnalyzerVersion = lockfile.pwsh.PSScriptAnalyzer or null;
  pwshYamlVersion = lockfile.pwsh."powershell-yaml" or null;

  profileContent =
    # check-suppress:config-method: method 4 (runtime embedded) -- init.ps1 and profile.ps1 are read at eval time and embedded into the activation block as a literal string. No deployment step needed.
    # __NUCLEUS_*__ tokens are Windows-only (substituted by Sync-ShellProfile.ps1); they become empty strings on POSIX, leaving the `if ($IsWindows)` blocks inert.
    builtins.replaceStrings
      [
        "__MANAGED_PREPEND_PATH__"
        "__MANAGED_APPEND_PATH__"
        "__ENV_CC__"
        "__ENV_CXX__"
        "__ENV_LD__"
        "__DEFAULT_DEV_TOOLS_PATH__"
        "__AGENT_ENV_VAR_NAMES__"
        "__AGENT_DEVIN_POSIX_PATH__"
        "__NUCLEUS_PREPEND_PATH__"
        "__NUCLEUS_APPEND_PATH__"
        "__NUCLEUS_LLVM_BIN_DIR__"
      ]
      [
        managedPaths.toPowerShellPrependSnippet
        managedPaths.toPowerShellAppendSnippet
        (envVars.resolveValue "CC" envVars.currentOs)
        (envVars.resolveValue "CXX" envVars.currentOs)
        (envVars.resolveValue "LD" envVars.currentOs)
        "${managedPaths.defaultDevTools}"
        (lib.concatStringsSep " " agentEnv.agentEnvVarNames)
        agentEnv.devinPosixPath
        ""
        ""
        ""
      ]
      (builtins.readFile ../scripts/shell/init.ps1 + builtins.readFile ../scripts/shell/profile.ps1)
  # PSScriptAnalyzerSettings.psd1 — Method 3 (consumed by scripts/check-pwsh.ps1 at CI time via -Settings); refer to scripts/PSScriptAnalyzerSettings.check.psd1 and scripts/PSScriptAnalyzerSettings.test.psd1.
  ;

  activationBundle = pkgs.callPackage ./lib/script-tree.nix { };
in
{
  # Place the PowerShell profile at the CurrentUserCurrentHost location for
  # interactive pwsh sessions.  On macOS and Linux, pwsh reads this path from
  # $PROFILE.CurrentUserCurrentHost at startup.
  home.file.".config/powershell/Microsoft.PowerShell_profile.ps1".text = profileContent;

  # Provisioned PSScriptAnalyzer settings file: Severity filter and ExcludeRules.
  # This is a reference copy that can be passed to Invoke-ScriptAnalyzer
  # via -Settings. PSSA does not auto-discover this path — it only discovers
  # PSScriptAnalyzerSettings.psd1 in the sibling directory of the analyzed file.
  # The CI copies consumed by scripts/check-pwsh.ps1 live at
  # scripts/PSScriptAnalyzerSettings.check.psd1 and
  # scripts/PSScriptAnalyzerSettings.test.psd1 (Method 3).
  home.file.".config/powershell/PSScriptAnalyzerSettings.psd1" = {
    # check-suppress:config-method: method 1 (writable symlink) -- repo changes take effect without rebuild.
    source = config.lib.file.mkOutOfStoreSymlink "${builtins.getEnv "NUCLEUS_REPO_ROOT"}/src/modules/configs/pwsh/PSScriptAnalyzerSettings.psd1";
  };

  # Install PSScriptAnalyzer for PowerShell linting if pwsh is available.
  # This enables the lint phase in scripts/check-pwsh.ps1.
  home.activation.install-pwsh-script-analyzer = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    "${activationBundle}/src/scripts/packages/install-pwsh-module.sh" \
      "${pkgs.powershell}/bin/pwsh" \
      "PSScriptAnalyzer" \
      "${pwshAnalyzerVersion}"
  '';

  # Install powershell-yaml for locked DSC validation if pwsh is available.
  # This enables the locked DSC validation phase in scripts/check.ps1.
  home.activation.install-pwsh-yaml = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    "${activationBundle}/src/scripts/packages/install-pwsh-module.sh" \
      "${pkgs.powershell}/bin/pwsh" \
      "powershell-yaml" \
      "${pwshYamlVersion}"
  '';
}
