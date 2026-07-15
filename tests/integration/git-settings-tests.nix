# tests/integration/git-settings-tests.nix — Validate shared Git defaults across POSIX and Windows.

let
  inherit (import ../lib.nix) containsRegex flatten;

  posixGitText = builtins.readFile ../../src/modules/git.nix;
  windowsGitText = builtins.readFile ../../src/hosts/Windows/modules/user/Sync-GitAndSshConfig.ps1;
in
assert containsRegex "core\.autocrlf = false" posixGitText;
assert containsRegex "core\.symlinks = true" posixGitText;
assert containsRegex "fetch\.prune = true" posixGitText;
assert containsRegex "fetch\.pruneTags = true" posixGitText;
assert containsRegex "push\.autoSetupRemote = true" posixGitText;
assert containsRegex "push\.followTags = true" posixGitText;
assert containsRegex "user\.useConfigOnly = true" posixGitText;
assert containsRegex "'core\.autocrlf' = 'true'" windowsGitText;
assert containsRegex "'core\.symlinks' = 'true'" windowsGitText;
assert containsRegex "'fetch\.prune' = 'true'" windowsGitText;
assert containsRegex "'fetch\.pruneTags' = 'true'" windowsGitText;
assert containsRegex "'push\.autoSetupRemote' = 'true'" windowsGitText;
assert containsRegex "'push\.followTags' = 'true'" windowsGitText;
assert containsRegex "'user\.useConfigOnly' = 'true'" windowsGitText;

# --- Preventative: init.templateDir suppresses new-repo boilerplate ---
assert containsRegex "init\.templateDir" posixGitText;
assert containsRegex "empty_template" posixGitText;
assert containsRegex "'init\.templateDir'" windowsGitText;
assert containsRegex "empty_template" windowsGitText;
assert containsRegex "gitEmptyTemplate" posixGitText;
{
  success = true;
  message = "Git settings cross-host parity tests passed";
}
