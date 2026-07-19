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
    # Method 4 (runtime embedded): init.ps1 and profile-base.ps1 are read at eval time and embedded into the activation block as a literal string. No deployment step needed.
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
      ]
      (builtins.readFile ../scripts/shell/init.ps1)
    + (builtins.readFile ./configs/pwsh/profile-base.ps1);
in
{
  # Place the PowerShell profile at the CurrentUserCurrentHost location for
  # interactive pwsh sessions.  On macOS and Linux, pwsh reads this path from
  # $PROFILE.CurrentUserCurrentHost at startup.
  home.file.".config/powershell/Microsoft.PowerShell_profile.ps1".text = profileContent;

  # Install PSScriptAnalyzer for PowerShell linting if pwsh is available.
  # This enables the lint phase in scripts/check-pwsh.ps1.
  home.activation.installPwshScriptAnalyzer = lib.hm.dag.entryAfter [ "writeBoundary" ] (
    builtins.replaceStrings
      [ "__PWSH_BIN__" "__MODULE_NAME__" "__MODULE_VERSION__" ]
      [ "${pkgs.powershell}/bin/pwsh" "PSScriptAnalyzer" pwshAnalyzerVersion ]
      (builtins.readFile ../scripts/packages/install-pwsh-module.sh)
  );

  # Install powershell-yaml for locked DSC validation if pwsh is available.
  # This enables the locked DSC validation phase in scripts/check.ps1.
  home.activation.installPwshYaml = lib.hm.dag.entryAfter [ "writeBoundary" ] (
    builtins.replaceStrings
      [ "__PWSH_BIN__" "__MODULE_NAME__" "__MODULE_VERSION__" ]
      [ "${pkgs.powershell}/bin/pwsh" "powershell-yaml" pwshYamlVersion ]
      (builtins.readFile ../scripts/packages/install-pwsh-module.sh)
  );
}
