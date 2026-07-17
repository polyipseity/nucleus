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
    let
      nixPreamble = ''
            # This file is managed by nucleus (src/modules/pwsh.nix).
            # Manual edits will be overwritten on the next `nix run .#apply`.



            # Managed PATH: prepend dirs (before system default).
            ${managedPaths.toPowerShellPrependSnippet}

            # Managed PATH: append dirs (after system default).
            # Canonical source: env-catalog.nix -> managed-paths.nix (pathComponents).
            ${managedPaths.toPowerShellAppendSnippet}


            # LLVM/Clang toolchain defaults sourced from the centralized env var
            # catalog.  All-process on all hosts.
            # Source: src/modules/lib/env-catalog.nix (CC, CXX, LD entries).
            $env:CC = "${envVars.resolveValue "CC" envVars.currentOs}"
            $env:CXX = "${envVars.resolveValue "CXX" envVars.currentOs}"
            $env:LD = "${envVars.resolveValue "LD" envVars.currentOs}"

            # Managed default dev tools path for profile functions.
            $global:NUCLEUS_DEFAULT_DEV_TOOLS = "${managedPaths.defaultDevTools}"

            # ---------------------------------------------------------------
            # AI agent session detection
            # ---------------------------------------------------------------
            # Environment variable names sourced from src/modules/agent-env-vars.nix.
            function Test-NucleusAgentSession {
        ${lib.concatStringsSep "\n" (
          map (v: "      if (Test-Path env:${v}) { return $true }") agentEnv.agentEnvVarNames
        )}
              if (Test-Path "${agentEnv.devinPosixPath}") { return $true }
              return $false
            }
      '';
      # Method 4 (runtime embedded): profile-base.ps1 is read at eval time and embedded into the
      # activation block as a literal string. No deployment step needed.
    in
    nixPreamble + (builtins.readFile ./configs/pwsh/profile-base.ps1);
in
{
  # Place the PowerShell profile at the CurrentUserCurrentHost location for
  # interactive pwsh sessions.  On macOS and Linux, pwsh reads this path from
  # $PROFILE.CurrentUserCurrentHost at startup.
  home.file.".config/powershell/Microsoft.PowerShell_profile.ps1".text = profileContent;

  # Install PSScriptAnalyzer for PowerShell linting if pwsh is available.
  # This enables the lint phase in scripts/check-pwsh.ps1.
  home.activation.installPwshScriptAnalyzer = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    _pwsh="${pkgs.powershell}/bin/pwsh"
    if [ -x "$_pwsh" ] && [ -n "${pwshAnalyzerVersion}" ]; then
      "$_pwsh" -NoProfile -Command "
        \$requiredVersion = '${pwshAnalyzerVersion}'
        \$installed = Get-Module -ListAvailable -Name PSScriptAnalyzer | Select-Object -First 1
        if (-not \$installed -or \$installed.Version -ne [Version]\$requiredVersion) {
          if (\$installed) {
            Write-Host 'installPwshScriptAnalyzer: removing PSScriptAnalyzer version '\$(\$installed.Version)'...' -ForegroundColor Yellow
            Uninstall-Module -Name PSScriptAnalyzer -AllVersions -Force
          }
          Write-Host 'installPwshScriptAnalyzer: installing PSScriptAnalyzer version \$requiredVersion...' -ForegroundColor Cyan
          Install-Module -Name PSScriptAnalyzer -RequiredVersion \$requiredVersion -Force -Scope CurrentUser -AllowClobber -ErrorAction Stop
        }
      "
    fi
  '';

  # Install powershell-yaml for locked DSC validation if pwsh is available.
  # This enables the locked DSC validation phase in scripts/check.ps1.
  home.activation.installPwshYaml = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    _pwsh="${pkgs.powershell}/bin/pwsh"
    if [ -x "$_pwsh" ] && [ -n "${pwshYamlVersion}" ]; then
      "$_pwsh" -NoProfile -Command "
        \$requiredVersion = '${pwshYamlVersion}'
        \$installed = Get-Module -ListAvailable -Name powershell-yaml | Select-Object -First 1
        if (-not \$installed -or \$installed.Version -ne [Version]\$requiredVersion) {
          if (\$installed) {
            Write-Host 'installPwshYaml: removing powershell-yaml version '\$(\$installed.Version)'...' -ForegroundColor Yellow
            Uninstall-Module -Name powershell-yaml -AllVersions -Force
          }
          Write-Host 'installPwshYaml: installing powershell-yaml version \$requiredVersion...' -ForegroundColor Cyan
          Install-Module -Name powershell-yaml -RequiredVersion \$requiredVersion -Force -Scope CurrentUser -AllowClobber -ErrorAction Stop
        }
      "
    fi
  '';
}
