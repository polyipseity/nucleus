let
  inherit (import ../lib.nix) containsRegex;

  # Read consumer source files
  agentsText = builtins.readFile ../../src/modules/agents.nix;
  defaultsText = builtins.readFile ../../src/hosts/MacBook/defaults.nix;
  editorsText = builtins.readFile ../../src/modules/editors.nix;
  gitText = builtins.readFile ../../src/modules/git.nix;
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
# Method 1 (writable symlink) consumers:
assert containsRegex "# Method 1" editorsText;
assert containsRegex "# Method 1" macosText;
assert containsRegex "# Method 1" homeText;
assert containsRegex "# Method 1 \\(writable symlink\\)" gitText;
assert containsRegex "# Method 1" shellText;
# Method 2 (read-only) consumers:
assert containsRegex "# Method 2" macbookBaseText;
assert containsRegex "# Method 2" macbookSecurityText;
assert containsRegex "# Method 2" macbookLinuxBuilderText;
assert containsRegex "# Method 1" posixBaseText;
# Method 3 (merge) consumers:
assert containsRegex "# Method 3" homeText;
assert containsRegex "# Method 3" qtpassText;
# Method 4 (runtime embedded) consumers:
assert containsRegex "# Method 4" pwshText;
assert containsRegex "# Method 4" defaultsText;
assert containsRegex "# Method 4" agentsText;
# Verify each host/service file that had method docs added
assert containsRegex "# Method 1" nixosServicesText;
# Verify key config files are referenced in their consumer files
assert containsRegex "system\\.gitignore" gitText;
assert containsRegex "wordlist\\.txt" defaultsText;
assert containsRegex "camilladsp/configs" homeText;
assert containsRegex "camillagui-backend/config" homeText;
assert containsRegex "linearmouse\\.json" macosText;
assert containsRegex "nix\\.custom\\.conf" macbookBaseText;
assert containsRegex "sshd_config\\.d" macbookSecurityText;
assert containsRegex "linux-builder-known_hosts" macbookLinuxBuilderText;
assert containsRegex "100-linux-builder\\.conf" macbookLinuxBuilderText;
assert containsRegex "profile-base\\.ps1" pwshText;
assert containsRegex "bunfig\\.toml" shellText;
assert containsRegex "config\\.toml" shellText;
assert containsRegex "direnvrc" shellText;
assert containsRegex "uv\\.toml" shellText;
assert containsRegex "agents/" agentsText;
{
  success = true;
  message = "Config method compliance tests passed";
}
