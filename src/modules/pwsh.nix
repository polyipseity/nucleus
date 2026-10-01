# PowerShell profile for POSIX hosts.
{
  config,
  lib,
  pkgs,
  repoRoot,
  username,
  managedUsername ? null,
  hostName,
  ...
}:
let
  effectiveUsername = if managedUsername != null then managedUsername else config.home.username;
  overlay = (import ./lib/users-overlay.nix { inherit lib; }).mkUserOverlay {
    inherit effectiveUsername repoRoot;
  };

  managedPaths = import ./lib/managed-paths.nix { inherit pkgs; };
  envVars = import ./lib/env-secrets.nix {
    inherit
      config
      pkgs
      lib
      username
      hostName
      ;
  };

  agentEnv = import ./shell/agent-env-vars.nix;

  # A single-host key resolves to null on other hosts, so the consumer guards on
  # the empty string and stays inert there.
  optionalEnv = value: if value == null then "" else value;

  lockfile = builtins.fromJSON (builtins.readFile ../lockfiles/lockfile.json);

  # A pin is a version string or a {version, hash} object, which is the schema's
  # contract rather than a fallback. A missing pin throws, so a renamed module
  # cannot install an empty spec.
  psgalleryVersion =
    module:
    let
      pin = lockfile.psgallery.${module} or (throw "lockfile.psgallery: no pin for ${module}");
    in
    if builtins.isString pin then pin else pin.version;

  pwshAnalyzerVersion = psgalleryVersion "PSScriptAnalyzer";
  pwshPesterVersion = psgalleryVersion "Pester";
  pwshYamlVersion = psgalleryVersion "powershell-yaml";

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
        "__ENV_SSH_AUTH_SOCK__"
        "__DEFAULT_DEV_TOOLS_PATH__"
        "__SSH_AGENT_TTY_BIN__"
        "__GPG_CONNECT_AGENT_BIN__"
        "__AGENT_ENV_VAR_NAMES__"
        "__AGENT_DEVIN_POSIX_PATH__"
        "__NUCLEUS_PREPEND_PATH__"
        "__NUCLEUS_APPEND_PATH__"
        "__NUCLEUS_LLVM_BIN_DIR__"
      ]
      [
        managedPaths.toPowerShellPrependSnippet
        managedPaths.toPowerShellAppendSnippet
        (envVars.resolveValue "CC" envVars.currentHost)
        (envVars.resolveValue "CXX" envVars.currentHost)
        (envVars.resolveValue "LD" envVars.currentHost)
        (optionalEnv (envVars.resolveValue "SSH_AUTH_SOCK" envVars.currentHost))
        "${managedPaths.defaultDevTools}"
        # macOS only: the SSH agent block needs the gpg-agent socket there.
        "/usr/bin/tty"
        "${pkgs.gnupg}/bin/gpg-connect-agent"
        (lib.concatStringsSep " " agentEnv.agentEnvVarNames)
        agentEnv.devinPosixPath
        ""
        ""
        ""
      ]
      (builtins.readFile ../scripts/shell/init.ps1 + builtins.readFile ../scripts/shell/profile.ps1)
  # A reference copy for Invoke-ScriptAnalyzer -Settings. PSSA does not
  # auto-discover this path, only a settings file beside the analyzed file.
  ;

  activationBundle = pkgs.callPackage ./lib/script-tree.nix { };
in
{
  # CurrentUserCurrentHost, where pwsh looks for the profile.
  home.file.".config/powershell/Microsoft.PowerShell_profile.ps1".text = profileContent;

  # Provisioned PSScriptAnalyzer settings file: Severity filter and ExcludeRules.
  # This is a reference copy that can be passed to Invoke-ScriptAnalyzer
  # via -Settings. PSSA does not auto-discover this path; it only discovers
  # PSScriptAnalyzerSettings.psd1 in the sibling directory of the analyzed file.
  # The CI copies consumed by src/scripts/checks/check-pwsh.ps1 live at
  # scripts/check-PSScriptAnalyzerSettings.psd1 and
  # scripts/test-PSScriptAnalyzerSettings.psd1 (Method 3).
  # Written against the live repo root so repo changes take effect without a
  # rebuild. Must run before protect-out-of-store-symlinks so the link gets
  # hardened; the writable/immutable decision is owned by managedSymlinkPaths.
  # check-suppress:config-method: method 1 (writable symlink) -- repo changes take effect without rebuild.
  home.activation.seed-pwsh-psscriptanalyzer-settings = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
    "${activationBundle}/src/scripts/configs/seed-writable-symlink.sh" \
      "${config.home.homeDirectory}/.config/powershell/PSScriptAnalyzerSettings.psd1" \
      "${overlay.toRepoRelPath (overlay.selectFile "pwsh" "PSScriptAnalyzerSettings.psd1")}" \
  '';

  # Stays imperative: the suite resets module state between runs for isolation
  # and a store path is read-only.
  home.activation.install-pwsh-pester = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    "${activationBundle}/src/scripts/packages/install-pwsh-module.sh" \
      "${pkgs.powershell}/bin/pwsh" \
      "Pester" \
      "${pwshPesterVersion}"
  '';

  # Needed by Invoke-ScriptAnalyzer in src/scripts/checks/check-pwsh.ps1.
  home.activation.install-pwsh-script-analyzer = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    "${activationBundle}/src/scripts/packages/install-pwsh-module.sh" \
      "${pkgs.powershell}/bin/pwsh" \
      "PSScriptAnalyzer" \
      "${pwshAnalyzerVersion}"
  '';

  # Needed by the locked DSC validation phase in scripts/check.ps1.
  home.activation.install-pwsh-yaml = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    "${activationBundle}/src/scripts/packages/install-pwsh-module.sh" \
      "${pkgs.powershell}/bin/pwsh" \
      "powershell-yaml" \
      "${pwshYamlVersion}"
  '';
}
