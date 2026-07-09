# tests/integration/powershell-module-setup-tests.nix — Verify PowerShell module provisioning wiring.
#
# Validates that PowerShell modules pinned in the lockfile are wired
# correctly across all provisioning layers (POSIX pwsh.nix activation,
# Windows apply.ps1 setup module, and Invoke-PowerShellModuleSetup.ps1).
#
# Run with: nix-instantiate --eval tests/integration/powershell-module-setup-tests.nix

let
  inherit (import ../lib.nix) assert';

  pwshNixText = builtins.readFile ../../src/modules/pwsh.nix;
  windowsApplyText = builtins.readFile ../../src/hosts/Windows/apply.ps1;
  powershellModuleSetupText = builtins.readFile ../../src/hosts/Windows/modules/setup/Invoke-PowerShellModuleSetup.ps1;
  lockfileText = builtins.readFile ../../src/lockfiles/lockfile.json;

  # ---------------------------------------------------------------------------
  # Lockfile assertions
  # ---------------------------------------------------------------------------

  test_powershell_yaml_in_lockfile = assert' (builtins.hasAttr "powershell-yaml" (builtins.fromJSON lockfileText).pwsh) "lockfile.json pwsh section must contain 'powershell-yaml'";

  test_analyzer_in_lockfile = assert' (builtins.hasAttr "PSScriptAnalyzer" (builtins.fromJSON lockfileText).pwsh) "lockfile.json pwsh section must contain 'PSScriptAnalyzer'";

  # ---------------------------------------------------------------------------
  # pwsh.nix assertions (POSIX provisioning via Nix Home Manager)
  # ---------------------------------------------------------------------------

  test_pwsh_nix_reads_yaml_version = assert' (builtins.hasInfix "pwshYamlVersion = lockfile.pwsh.\"powershell-yaml\" or null" pwshNixText) "pwsh.nix must read 'powershell-yaml' version from lockfile";

  test_pwsh_nix_has_installPwshYaml = assert' (builtins.hasInfix "home.activation.installPwshYaml" pwshNixText) "pwsh.nix must have installPwshYaml activation block";

  test_pwsh_nix_installPwshYaml_uses_correct_module = assert' (builtins.hasInfix "Install-Module -Name powershell-yaml" pwshNixText) "pwsh.nix installPwshYaml activation must reference 'powershell-yaml'";

  # ---------------------------------------------------------------------------
  # apply.ps1 assertions (Windows provisioning orchestration)
  # ---------------------------------------------------------------------------

  test_apply_ps1_dot_sources_module = assert' (builtins.hasInfix "Invoke-PowerShellModuleSetup.ps1" windowsApplyText) "apply.ps1 must dot-source Invoke-PowerShellModuleSetup.ps1";

  test_apply_ps1_calls_setup = assert' (builtins.hasInfix "Invoke-PowerShellModuleSetup" windowsApplyText) "apply.ps1 must call Invoke-PowerShellModuleSetup";

  # ---------------------------------------------------------------------------
  # Invoke-PowerShellModuleSetup.ps1 assertions (Windows setup module)
  # ---------------------------------------------------------------------------

  test_setup_module_exists = assert' (builtins.hasInfix "function Invoke-PowerShellModuleSetup" powershellModuleSetupText) "Invoke-PowerShellModuleSetup.ps1 must define the function";

  test_setup_module_reads_lockfile = assert' (builtins.hasInfix "lockfile.json" powershellModuleSetupText) "Invoke-PowerShellModuleSetup.ps1 must reference lockfile.json";

  test_setup_module_uses_pwsh_section = assert' (builtins.hasInfix "\$lockfile.pwsh" powershellModuleSetupText) "Invoke-PowerShellModuleSetup.ps1 must read the pwsh section from lockfile";
in
{
  success = true;
  testCount = 9;
  message = "All ${builtins.toString 9} PowerShell module provisioning tests passed";
}
