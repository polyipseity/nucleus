# tests/modules/starship-tests.nix — Validate starship module and config.
#
# Verifies:
#   • Module can be imported and defines expected options
#   • Config TOML exists and contains expected sections
#
# Run with: nix-instantiate --eval tests/modules/starship-tests.nix

let
  lib = import <nixpkgs/lib>;
  pkgs = import <nixpkgs> { };
  inherit (lib) hasInfix;

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

  # Verify config contains expected module sections.
  hasDirectory = hasInfix "[directory]" configFile;
  hasGitBranch = hasInfix "[git_branch]" configFile;
  hasGitStatus = hasInfix "[git_status]" configFile;
  hasNixShell = hasInfix "[nix_shell]" configFile;
  hasCmdDuration = hasInfix "[cmd_duration]" configFile;
  hasStatus = hasInfix "[status]" configFile;

  # Verify XDG config file is wired.
  hasXDGConfig = module.xdg.configFile ? "starship.toml" || false;

  # Verify STARSHIP_CACHE session variable.
  hasStarShipCache = (module.home.sessionVariables.STARSHIP_CACHE or "") != "";

in
{
  module_imports_cleanly = builtins.isAttrs module;
  starship_configured = packagesNonEmpty;
  config_file_nonempty = configNonEmpty;
  has_directory_section = hasDirectory;
  has_git_branch_section = hasGitBranch;
  has_git_status_section = hasGitStatus;
  has_nix_shell_section = hasNixShell;
  has_cmd_duration_section = hasCmdDuration;
  has_status_section = hasStatus;
  has_xdg_config = hasXDGConfig;
  has_starship_cache_var = hasStarShipCache;
  all_tests_pass =
    builtins.isAttrs module
    && packagesNonEmpty
    && configNonEmpty
    && hasDirectory
    && hasGitBranch
    && hasGitStatus
    && hasNixShell
    && hasCmdDuration
    && hasStatus
    && hasXDGConfig
    && hasStarShipCache;
}
