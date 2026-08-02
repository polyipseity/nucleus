# tests/integration/git-settings-tests.nix — Validate shared Git defaults and alias parity across POSIX and Windows.

let
  inherit (import ../lib.nix) containsRegex;

  posixGitText = builtins.readFile ../../src/modules/git.nix;
  windowsGitText = builtins.readFile ../../src/hosts/Windows/modules/user/Sync-GitAndSshConfig.ps1;

  # User-scope POSIX files live in src/users/default/git/ (defaults fallback:
  # per-user src/users/<username>/git/ wins when present).  Global-scope
  # settings live in src/modules/configs/git/<host>.gitconfig (Phase 2).
  macbookUserGitText = builtins.readFile ../../src/users/default/git/MacBook.gitconfig;
  nixosUserGitText = builtins.readFile ../../src/users/default/git/NixOS.gitconfig;
  macbookUserIgnoreText = builtins.readFile ../../src/users/default/git/MacBook.gitignore;
  nixosUserIgnoreText = builtins.readFile ../../src/users/default/git/NixOS.gitignore;
  macbookGlobalGitText = builtins.readFile ../../src/modules/configs/git/MacBook.gitconfig;
  nixosGlobalGitText = builtins.readFile ../../src/modules/configs/git/NixOS.gitconfig;

  # Alias parity: all three shells (zsh, POSIX pwsh, Windows pwsh) must expose
  # the same set of `-g*` shell aliases.  POSIX and Windows PowerShell both
  # consume the shared profile.ps1 (pwsh.nix at eval time, Sync-ShellProfile.ps1
  # at runtime), so one source is checked for both platforms.
  aliasesNix = builtins.readFile ../../src/modules/shell/aliases.nix;
  posixPwshAliases = builtins.readFile ../../src/scripts/shell/profile.ps1;
  windowsPwshAliases = builtins.readFile ../../src/scripts/shell/profile.ps1;

  # Count occurrences of a regex pattern in text by splitting on it.
  countMatches =
    pattern: text:
    builtins.length (builtins.filter (s: !builtins.isString s) (builtins.split pattern text));

  # Count `-g*` alias definitions in aliases.nix.
  # Matches `"-g` which starts every git and ghostscript alias line.
  # Multi-line alias values do not contain `"-g`, so this is accurate.
  aliasesNixCount = countMatches ''"-g'' aliasesNix;
  # Count `Add-ShellAlias '-g` definitions in the shared PowerShell profile.
  posixPwshCount = countMatches "Add-ShellAlias '-g" posixPwshAliases;
  windowsPwshCount = countMatches "Add-ShellAlias '-g" windowsPwshAliases;

  # Settings are shared verbatim across MacBook/NixOS (per-host divergence is a
  # future option; parity is asserted so accidental drift fails the test).
  userGitParity = macbookUserGitText == nixosUserGitText;
  userIgnoreParity = macbookUserIgnoreText == nixosUserIgnoreText;
  globalGitParity = macbookGlobalGitText == nixosGlobalGitText;
in
# --- POSIX user-scope settings (INI, src/users/default/git/<host>.gitconfig) ---
assert userGitParity;
assert containsRegex "excludesFile = ~/.config/git/ignore" macbookUserGitText;
assert containsRegex "prune = true" macbookUserGitText;
assert containsRegex "pruneTags = false" macbookUserGitText;
assert containsRegex "ff = true" macbookUserGitText;
assert containsRegex "rebase = false" macbookUserGitText;
assert containsRegex "autoSetupRemote = true" macbookUserGitText;
assert containsRegex "followTags = true" macbookUserGitText;
assert containsRegex "defaultBranch = main" macbookUserGitText;
assert containsRegex "templateDir = ~/.config/git/empty_template" macbookUserGitText;
assert containsRegex "program = gpg" macbookUserGitText;
assert containsRegex "path = ~/.config/git/identity" macbookUserGitText;
assert containsRegex "insteadOf = https://github.com/" macbookUserGitText;
assert containsRegex "useConfigOnly = true" macbookUserGitText;
# Global-scope settings must NOT leak into the user-scope file.
assert !(containsRegex "autocrlf = false" macbookUserGitText);
assert !(containsRegex "symlinks = true" macbookUserGitText);

# --- POSIX user-scope ignore (src/users/default/git/<host>.gitignore) ---
assert userIgnoreParity;
assert containsRegex "result" macbookUserIgnoreText;
assert containsRegex "result-\*" macbookUserIgnoreText;
assert containsRegex "\.direnv" macbookUserIgnoreText;
assert containsRegex "nixos-test-history" macbookUserIgnoreText;
assert containsRegex "metadata_never_index" macbookUserIgnoreText;

# --- POSIX global-scope settings (src/modules/configs/git/<host>.gitconfig) ---
assert globalGitParity;
assert containsRegex "gpgsign = true" macbookGlobalGitText;
assert containsRegex "autocrlf = false" macbookGlobalGitText;
assert containsRegex "symlinks = true" macbookGlobalGitText;

# --- POSIX git.nix wiring: symlinks with defaults-fallback selection ---
assert containsRegex "home\.file" posixGitText;
assert containsRegex "mkOutOfStoreSymlink.*gitconfig" posixGitText;
assert containsRegex "configFile\.\"git/ignore\"" posixGitText;
assert containsRegex "builtins\.pathExists" posixGitText;
assert containsRegex "src/users/default/git" posixGitText;
# The old global-ignore/assembly mechanism and programs.git settings are gone.
assert !(containsRegex "ignore-global" posixGitText);
assert !(containsRegex "assemble-gitignore" posixGitText);
assert !(containsRegex "programs\.git" posixGitText);

# --- Windows settings (Phase 4 scope; kept for parity until then) ---
assert containsRegex "'core\.autocrlf' = 'true'" windowsGitText;
assert containsRegex "'core\.symlinks' = 'true'" windowsGitText;
assert containsRegex "'fetch\.prune' = 'true'" windowsGitText;
assert containsRegex "'fetch\.pruneTags' = 'false'" windowsGitText;
assert containsRegex "'pull\.ff' = 'true'" windowsGitText;
assert containsRegex "'pull\.rebase' = 'false'" windowsGitText;
assert containsRegex "'push\.autoSetupRemote' = 'true'" windowsGitText;
assert containsRegex "'push\.followTags' = 'true'" windowsGitText;
assert containsRegex "'user\.useConfigOnly' = 'true'" windowsGitText;

# --- Preventative: init.templateDir suppresses new-repo boilerplate ---
# INI format splits dotted keys into [section] + key lines, so assert the
# key/value pair (and the empty_template dir it points at) instead.
assert containsRegex "templateDir = ~/.config/git/empty_template" macbookUserGitText;
assert containsRegex "empty_template" posixGitText;
assert containsRegex "'init\.templateDir'" windowsGitText;
assert containsRegex "empty_template" windowsGitText;

# --- Preventative: cross-host alias parity ---
assert aliasesNixCount == posixPwshCount && posixPwshCount == windowsPwshCount;
{
  success = true;
  message = "Git settings cross-host parity tests passed (aliasesNix=${toString aliasesNixCount}, posixPwsh=${toString posixPwshCount}, windowsPwsh=${toString windowsPwshCount})";
}
