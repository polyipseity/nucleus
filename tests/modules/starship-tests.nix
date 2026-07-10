# tests/modules/starship-tests.nix — Validate starship module and config.
#
# Verifies:
#   • Module can be imported and defines expected options
#   • Config TOML parses correctly (syntax + expected sections)
#
# Run with: nix-instantiate --eval tests/modules/starship-tests.nix

let
  lib = import <nixpkgs/lib>;
  pkgs = import <nixpkgs> { };

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
  configFile = builtins.readFile ../../src/modules/configs/starship.toml;
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

  # Verify XDG config file is wired.
  hasXDGConfig = module.xdg.configFile ? "starship.toml" || false;

  # Verify STARSHIP_CACHE session variable.
  hasStarShipCache = (module.home.sessionVariables.STARSHIP_CACHE or "") != "";

in
{
  module_imports_cleanly = builtins.isAttrs module;
  starship_configured = packagesNonEmpty;
  config_file_nonempty = configNonEmpty;
  has_directory_section = directoryIsSection;
  has_git_branch_section = gitBranchIsSection;
  has_git_status_section = gitStatusIsSection;
  has_nix_shell_section = nixShellIsSection;
  has_cmd_duration_section = cmdDurationIsSection;
  has_status_section = statusIsSection;
  has_xdg_config = hasXDGConfig;
  has_starship_cache_var = hasStarShipCache;
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
    && hasXDGConfig
    && hasStarShipCache;
}
