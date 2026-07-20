# tests/integration/git-settings-tests.nix — Validate shared Git defaults and alias parity across POSIX and Windows.

let
  lib = import <nixpkgs/lib>;
  inherit (import ../lib.nix) containsRegex flatten;

  posixGitText = builtins.readFile ../../src/modules/git.nix;
  windowsGitText = builtins.readFile ../../src/hosts/Windows/modules/user/Sync-GitAndSshConfig.ps1;

  # Alias parity: all three shells (zsh, POSIX pwsh, Windows pwsh) must expose
  # the same set of `-g*` shell aliases.
  aliasesNix = builtins.readFile ../../src/modules/shell/aliases.nix;
  posixPwshAliases = builtins.readFile ../../src/modules/configs/pwsh/profile-base.ps1;
  windowsPwshAliases = builtins.readFile ../../src/hosts/Windows/modules/user/Sync-ShellProfile.ps1;

  # Count occurrences of a regex pattern in text by splitting on it.
  countMatches =
    pattern: text:
    builtins.length (builtins.filter (s: !builtins.isString s) (builtins.split pattern text));

  # Count `-g*` alias definitions in aliases.nix.
  # Matches `"-g` which starts every git and ghostscript alias line.
  # Multi-line alias values do not contain `"-g`, so this is accurate.
  aliasesNixCount = countMatches ''"-g'' aliasesNix;
  # Count `function -g` definitions in both PowerShell profiles.
  posixPwshCount = countMatches "function -g" posixPwshAliases;
  windowsPwshCount = countMatches "function -g" windowsPwshAliases;
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

# --- Preventative: cross-host alias parity ---
assert aliasesNixCount == posixPwshCount && posixPwshCount == windowsPwshCount;
{
  success = true;
  message = "Git settings cross-host parity tests passed (aliasesNix=${toString aliasesNixCount}, posixPwsh=${toString posixPwshCount}, windowsPwsh=${toString windowsPwshCount})";
}
