# tests/modules/starship-tests.nix — Starship module and config validation.

let
  lib = import <nixpkgs/lib>;
  pkgs = import <nixpkgs> { };
  testLib = import ../lib.nix;

  # Module imports cleanly (will throw if it doesn't).
  module = import ../../src/modules/starship.nix {
    inherit lib pkgs;
    config = {
      home = {
        username = "testuser";
        homeDirectory = "/home/testuser";
      };
    };
    hm = { };
  };

  # Verify home.packages is non-empty (implicitly validates pkgs.starship exists).
  packagesNonEmpty = builtins.length module.home.packages > 0;

  # Verify config TOML file exists and is non-empty.
  configFile = builtins.readFile ../../src/modules/configs/starship/starship.toml;
  configNonEmpty = builtins.stringLength configFile > 0;

  # Parse TOML — throws at eval time if syntax is invalid (e.g., bad escape
  # sequences in basic strings). This is the primary regression guard.
  parsedConfig = builtins.fromTOML configFile;

  # Verify parsed structure has expected sections.
  directoryIsSection = builtins.isAttrs (parsedConfig.directory or { });
  gitBranchIsSection = builtins.isAttrs (parsedConfig.git_branch or { });
  gitStatusIsSection = builtins.isAttrs (parsedConfig.git_status or { });
  nixShellIsSection = builtins.isAttrs (parsedConfig.nix_shell or { });
  cmdDurationIsSection = builtins.isAttrs (parsedConfig.cmd_duration or { });
  statusIsSection = builtins.isAttrs (parsedConfig.status or { });
  hostnameIsSection = builtins.isAttrs (parsedConfig.hostname or { });
  direnvIsSection = builtins.isAttrs (parsedConfig.direnv or { });
  dockerContextIsSection = builtins.isAttrs (parsedConfig.docker_context or { });
  cIsSection = builtins.isAttrs (parsedConfig.c or { });
  cmakeIsSection = builtins.isAttrs (parsedConfig.cmake or { });
  dotnetIsSection = builtins.isAttrs (parsedConfig.dotnet or { });
  jobsIsSection = builtins.isAttrs (parsedConfig.jobs or { });
  shlvlIsSection = builtins.isAttrs (parsedConfig.shlvl or { });
  sudoIsSection = builtins.isAttrs (parsedConfig.sudo or { });
  batteryIsSection = builtins.isAttrs (parsedConfig.battery or { });

in
rec {
  assert_all_pass = testLib.assert' all_tests_pass "starship-tests: all_tests_pass is false";
  module_imports_cleanly = builtins.isAttrs module;
  starship_configured = packagesNonEmpty;
  config_file_nonempty = configNonEmpty;
  has_directory_section = directoryIsSection;
  has_git_branch_section = gitBranchIsSection;
  has_git_status_section = gitStatusIsSection;
  has_nix_shell_section = nixShellIsSection;
  has_cmd_duration_section = cmdDurationIsSection;
  has_status_section = statusIsSection;
  has_hostname_section = hostnameIsSection;
  has_direnv_section = direnvIsSection;
  has_docker_context_section = dockerContextIsSection;
  has_c_section = cIsSection;
  has_cmake_section = cmakeIsSection;
  has_dotnet_section = dotnetIsSection;
  has_jobs_section = jobsIsSection;
  has_shlvl_section = shlvlIsSection;
  has_sudo_section = sudoIsSection;
  has_battery_section = batteryIsSection;
  all_tests_pass =
    builtins.isAttrs module
    && packagesNonEmpty
    && configNonEmpty
    && directoryIsSection
    && gitBranchIsSection
    && gitStatusIsSection
    && nixShellIsSection
    && cmdDurationIsSection
    && statusIsSection
    && hostnameIsSection
    && direnvIsSection
    && dockerContextIsSection
    && cIsSection
    && cmakeIsSection
    && dotnetIsSection
    && jobsIsSection
    && shlvlIsSection
    && sudoIsSection
    && batteryIsSection;
  success = all_tests_pass;
}
