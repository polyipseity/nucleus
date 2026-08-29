let
  inherit (import ../../../lib.nix) containsRegex;

  # Read consumer source files
  agentsText = builtins.readFile ../../../../src/modules/agents.nix;
  defaultsText = builtins.readFile ../../../../src/hosts/MacBook/defaults.nix;
  editorsText = builtins.readFile ../../../../src/modules/editors.nix;
  gitText = builtins.readFile ../../../../src/modules/git.nix;
  usersOverlayText = builtins.readFile ../../../../src/modules/lib/users-overlay.nix;
  homeText = builtins.readFile ../../../../src/modules/home.nix;
  discordMusicRpcText = builtins.readFile ../../../../src/modules/ext-discord-music-rpc.nix;
  iterm2Text = builtins.readFile ../../../../src/modules/iterm2.nix;
  macosText = builtins.readFile ../../../../src/platforms/macOS/modules/default.nix;
  posixBaseText = builtins.readFile ../../../../src/modules/posix-base.nix;
  pwshText = builtins.readFile ../../../../src/modules/pwsh.nix;
  shellText = builtins.readFile ../../../../src/modules/shell.nix;
  starshipText = builtins.readFile ../../../../src/modules/starship.nix;
  # Host-specific files
  macbookBaseText = builtins.readFile ../../../../src/hosts/MacBook/base.nix;
  macbookLinuxBuilderText = builtins.readFile ../../../../src/hosts/MacBook/linux-builder.nix;
  macbookSecurityText = builtins.readFile ../../../../src/hosts/MacBook/security.nix;
  nixosServicesText = builtins.readFile ../../../../src/hosts/NixOS/services.nix;
  # Config definition files
  qtpassText = builtins.readFile ../../../../src/modules/configs/qtpass/qtpass.nix;
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
assert containsRegex "mkUserOverlay" defaultsText;
assert containsRegex "selectFile" defaultsText;
assert containsRegex "camilladsp/configs" homeText;
assert containsRegex "camillagui-backend/config" homeText;
# Method 1 (writable symlink) deployments MUST be marked writable = true in
# managedSymlinkPaths, otherwise the symlink is hardened immutable (uchg/chattr +i)
# and the app cannot write the active config back through it.
assert containsRegex "camilladsp/configs\";[[:space:]]*writable = true" homeText;
assert containsRegex "discord-music-rpc/config.yaml\";[[:space:]]*writable = true" homeText;
# Ban: a Method 1 (writable symlink) path must never appear as a non-writable
# managedSymlinkPaths entry. A non-writable entry is hardened immutable
# (uchg/chattr +i) and the app cannot write the active config back through it —
# the camilladsp "can read but cannot write" regression. The two Method 1 paths
# below must each be present as `writable = true`, and must NOT appear as a bare
# `{ path = "..."; }` (immutable) entry.
assert !(containsRegex "camilladsp/configs\";[[:space:]]*}" homeText);
assert !(containsRegex "discord-music-rpc/config.yaml\";[[:space:]]*}" homeText);
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
# Phase 3: method-1 (writable symlink) deployments MUST be created at activation
# time against the LIVE repo root via seed-writable-symlink.sh — never via
# mkOutOfStoreSymlink with a repoRoot-derived path (repoRoot is a read-only
# /nix/store/*-source snapshot, so writes fail with EACCES -> HTTP 500 and repo
# edits don't take effect without rebuild). Assert the seed-* activation entries
# exist and that mkOutOfStoreSymlink is no longer used for these paths.
assert containsRegex "seed-writable-symlink\\.sh" gitText;
assert containsRegex "seed-git-gitconfig" gitText;
assert containsRegex "seed-git-gitignore" gitText;
assert containsRegex "seed-starship-config" starshipText;
assert containsRegex "seed-camilladsp-configs" homeText;
assert containsRegex "seed-camillagui-config" homeText;
assert containsRegex "seed-discord-music-rpc-config" discordMusicRpcText;
assert containsRegex "seed-iterm2-dynamic-profiles" iterm2Text;
assert containsRegex "seed-bunfig" shellText;
assert containsRegex "seed-cargo-config" shellText;
assert containsRegex "seed-nextest-config" shellText;
assert containsRegex "seed-direnvrc" shellText;
assert containsRegex "seed-direnv-apple-sdk-override" shellText;
assert containsRegex "seed-uv-config" shellText;
assert containsRegex "seed-pwsh-psscriptanalyzer-settings" pwshText;
assert containsRegex "seed-open-manual" nixosServicesText;
assert containsRegex "seed-nucleus-manual-desktop" nixosServicesText;
assert containsRegex "seed-nucleus-optimize-pdf-desktop" nixosServicesText;
# Ban mkOutOfStoreSymlink for the method-1 repo-sourced paths (would bake the
# read-only store snapshot as the symlink target). The helper seed-writable-symlink.sh
# resolves the LIVE repo root at activation time instead.
assert !(containsRegex "mkOutOfStoreSymlink" gitText);
assert
  !(containsRegex "config\\.lib\\.file\\.mkOutOfStoreSymlink.*(camilladsp|camillagui)" homeText);
assert !(containsRegex "mkOutOfStoreSymlink" shellText);
assert !(containsRegex "mkOutOfStoreSymlink" pwshText);
assert !(containsRegex "mkOutOfStoreSymlink" nixosServicesText);
{
  success = true;
  message = "Config method compliance tests passed";
}
