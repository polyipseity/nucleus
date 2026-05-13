# tests/nix/git-settings-tests.nix — Validate shared Git defaults across POSIX and Windows.
#
# Locks the declarative Git baseline in both src/modules/git.nix and the
# Windows Sync-GitAndSshConfig module so cross-host parity regressions are
# caught even when the runtime tests are not executed on this platform.

let
  flatten = text: builtins.replaceStrings [ "\n" "\r" ] [ " " " " ] text;

  containsRegex = pattern: haystack: builtins.match ".*${pattern}.*" (flatten haystack) != null;

  posixGitText = builtins.readFile ../../src/modules/git.nix;
  windowsGitText = builtins.readFile ../../src/hosts/windows/modules/user/Sync-GitAndSshConfig.ps1;
in
assert containsRegex "core\.autocrlf = false" posixGitText;
assert containsRegex "core\.symlinks = true" posixGitText;
assert containsRegex "fetch\.prune = true" posixGitText;
assert containsRegex "fetch\.pruneTags = true" posixGitText;
assert containsRegex "push\.followTags = true" posixGitText;
assert containsRegex "user\.useConfigOnly = true" posixGitText;
assert containsRegex "'core\.autocrlf' = 'true'" windowsGitText;
assert containsRegex "'core\.symlinks' = 'true'" windowsGitText;
assert containsRegex "'fetch\.prune' = 'true'" windowsGitText;
assert containsRegex "'fetch\.pruneTags' = 'true'" windowsGitText;
assert containsRegex "'push\.followTags' = 'true'" windowsGitText;
assert containsRegex "'user\.useConfigOnly' = 'true'" windowsGitText;
true
