let
  inherit (import ../lib.nix) containsRegex;

  # Read consumer source files
  agentsText = builtins.readFile ../../src/modules/agents.nix;
  defaultsText = builtins.readFile ../../src/hosts/MacBook/defaults.nix;
  editorsText = builtins.readFile ../../src/modules/editors.nix;
  gitText = builtins.readFile ../../src/modules/git.nix;
  usersOverlayText = builtins.readFile ../../src/modules/lib/users-overlay.nix;
  homeText = builtins.readFile ../../src/modules/home.nix;
  macosText = builtins.readFile ../../src/modules/macos.nix;
  posixBaseText = builtins.readFile ../../src/modules/posix-base.nix;
  pwshText = builtins.readFile ../../src/modules/pwsh.nix;
  shellText = builtins.readFile ../../src/modules/shell.nix;
  # Host-specific files
  macbookBaseText = builtins.readFile ../../src/hosts/MacBook/base.nix;
  macbookLinuxBuilderText = builtins.readFile ../../src/hosts/MacBook/linux-builder.nix;
  macbookSecurityText = builtins.readFile ../../src/hosts/MacBook/security.nix;
  nixosServicesText = builtins.readFile ../../src/hosts/NixOS/services.nix;
  # Config definition files
  qtpassText = builtins.readFile ../../src/modules/configs/qtpass/qtpass.nix;
in
# Verify method comments exist on all consumer files.
# method 1 (writable symlink) consumers:
assert containsRegex "# check-suppress:config-method: method 1" editorsText;
assert containsRegex "# check-suppress:config-method: method 1" macosText;
assert containsRegex "# check-suppress:config-method: method 1" homeText;
assert containsRegex "# check-suppress:config-method: method 1 \\(writable symlink\\)" gitText;
assert containsRegex "# check-suppress:config-method: method 1" shellText;
# method 2 (read-only) consumers:
assert containsRegex "# check-suppress:config-method: method 2" macbookBaseText;
assert containsRegex "# check-suppress:config-method: method 2" macbookSecurityText;
assert containsRegex "# check-suppress:config-method: method 2" macbookLinuxBuilderText;
assert containsRegex "# check-suppress:config-method: method 1" posixBaseText;
# method 3 (merge) consumers:
assert containsRegex "# check-suppress:config-method: method 3" homeText;
assert containsRegex "# check-suppress:config-method: method 3" qtpassText;
# method 4 (runtime embedded) consumers:
assert containsRegex "# check-suppress:config-method: method 4" pwshText;
assert containsRegex "# check-suppress:config-method: method 4" defaultsText;
assert containsRegex "# check-suppress:config-method: method 4" agentsText;
# Verify each host/service file that had method docs added
assert containsRegex "# check-suppress:config-method: method 1" nixosServicesText;
# Verify key config files are referenced in their consumer files
# Phase 3: git.nix wires the user-scope ~/.gitconfig and ~/.config/git/ignore to
# src/users/<username>/git/ with a src/users/default/git/ defaults fallback via
# the generic overlay selector (src/modules/lib/users-overlay.nix); the old
# ignore-global/assembly mechanism is gone.
assert containsRegex "\\.gitconfig" gitText;
assert containsRegex "git/ignore" gitText;
assert containsRegex "selectSource \"git\"" gitText;
assert containsRegex "mkUserOverlay" usersOverlayText;
assert !(containsRegex "system\\.gitignore" gitText);
assert !(containsRegex "ignore-global" gitText);
# Phase 2: global gitconfig is per-host (${hostName}.gitconfig), no more system.gitconfig.
assert containsRegex "\\.gitconfig" posixBaseText;
assert !(containsRegex "system\\.gitconfig" posixBaseText);
assert containsRegex "wordlist\\.txt" defaultsText;
assert containsRegex "camilladsp/configs" homeText;
assert containsRegex "camillagui-backend/config" homeText;
assert containsRegex "linearmouse\\.json" macosText;
assert containsRegex "nix\\.custom\\.conf" macbookBaseText;
assert containsRegex "sshd_config\\.d" macbookSecurityText;
assert containsRegex "linux-builder-known_hosts" macbookLinuxBuilderText;
assert containsRegex "100-linux-builder\\.conf" macbookLinuxBuilderText;
assert containsRegex "scripts/shell/profile\\.ps1" pwshText;
assert containsRegex "bunfig\\.toml" shellText;
assert containsRegex "config\\.toml" shellText;
assert containsRegex "direnvrc" shellText;
assert containsRegex "lib/apple-sdk-override\.sh" shellText;
assert containsRegex "uv\\.toml" shellText;
assert containsRegex "nextest/config\\.toml" shellText;
assert containsRegex "mkUserOverlay" shellText;
assert containsRegex "selectFile" shellText;
assert containsRegex "agents/" agentsText;
{
  success = true;
  message = "Config method compliance tests passed";
}
