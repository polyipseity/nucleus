let
  inherit (import ../lib.nix) containsRegex;

  usersOverlayText = builtins.readFile ../../src/modules/lib/users-overlay.nix;
  shellText = builtins.readFile ../../src/modules/shell.nix;
  agentsText = builtins.readFile ../../src/modules/agents.nix;
  pwshText = builtins.readFile ../../src/modules/pwsh.nix;
  gitSystemText = builtins.readFile ../../src/modules/configs/git/MacBook.gitconfig;
  gitUserText = builtins.readFile ../../src/modules/git.nix;
  resolveUserConfigText = builtins.readFile ../../src/scripts/lib/resolve-user-config.sh;
  configHelpersText = builtins.readFile ../../src/hosts/Windows/modules/ConfigHelpers.ps1;
in
assert containsRegex "mkUserOverlay" usersOverlayText;
assert containsRegex "mkUserOverlay" shellText;
assert containsRegex "mkUserOverlay" agentsText;
assert containsRegex "resolve_user_config_dir" resolveUserConfigText;
assert containsRegex "Deploy-UserWritableSymlink" configHelpersText;
assert
  containsRegex "src/modules/configs/git/" gitSystemText
  || builtins.pathExists ../../src/modules/configs/git/MacBook.gitconfig;
assert containsRegex "selectSource \"git\"" gitUserText;
assert !containsRegex "src/modules/configs/(direnv|cargo|bun|uv|nextest|agents|pwsh)" shellText;
assert !containsRegex "src/modules/configs/(direnv|cargo|bun|uv|nextest|agents|pwsh)" agentsText;
assert !containsRegex "src/modules/configs/(direnv|cargo|bun|uv|nextest|agents|pwsh)" pwshText;
{
  success = true;
  message = "user-config-placement tests passed";
}
