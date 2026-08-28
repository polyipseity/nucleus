# iTerm2 terminal emulator configuration.
#
# Houses iTerm2 shell integration script, Dynamic Profiles directory symlink,
# and zsh initContent sourcing guard.  NSUserDefaults keys are in
# src/hosts/MacBook/defaults.nix (darwin context, where
# system.defaults.CustomUserPreferences is available).
#
# Parity note: iTerm2 is macOS-only.  No equivalent exists on NixOS/Windows.
#
# Source: https://iterm2.com/documentation.html
{
  config,
  lib,
  pkgs,
  repoRoot,
  managedUsername ? null,
  username ? null,
  ...
}:
let
  effectiveUsername =
    if managedUsername != null then
      managedUsername
    else if username != null then
      username
    else
      config.home.username;

  # Pinned iTerm2 zsh shell integration script placed at
  # ~/.iterm2_shell_integration.zsh via home.file.  The script enables command
  # marks, command history, directory reporting, and in-terminal image display
  # in iTerm2 sessions; it is sourced at zsh startup via programs.zsh.initContent.
  # Update sha256 when iTerm2 publishes a new integration revision:
  #   nix-prefetch-url https://iterm2.com/shell_integration/zsh
  iterm2ZshIntegration = pkgs.fetchurl {
    url = "https://iterm2.com/shell_integration/zsh";
    sha256 = "0yhfnaigim95sk1idrc3hpwii8hfhjl5m3lyc0ip3vi1a9npq0li";
  };
  # Root of the nucleus repository, set by apply.sh at activation time.

  overlay = (import ./lib/users-overlay.nix).mkUserOverlay {
    inherit effectiveUsername repoRoot;
  };

  iterm2DynamicProfilesDir = overlay.selectFirstLevelEntry "iterm2" "DynamicProfiles";

  # Activation helper bundle (seed-writable-symlink.sh) resolved at eval time;
  # the helper itself resolves the LIVE repo root at activation time.
  activationBundle = pkgs.callPackage ./lib/script-tree.nix { };
in
lib.mkIf pkgs.stdenv.hostPlatform.isDarwin {
  home.file = {
    # Place the pinned iTerm2 zsh shell integration script at the well-known
    # path that the sourcing guard in programs.zsh.initContent expects.
    # home.file replaces the symlink atomically on each home-manager switch so
    # the script version tracks the pinned hash in iterm2ZshIntegration above.
    ".iterm2_shell_integration.zsh".source = iterm2ZshIntegration;
  };

  # Method-1 (writable) symlink for the iTerm2 Dynamic Profiles directory. Created
  # at activation time against the LIVE repo root so profile edits take effect
  # without rebuild. The writable/immutable decision is owned by managedSymlinkPaths;
  # this entry must run before protect-out-of-store-symlinks so the link is hardened
  # if immutable.
  # check-suppress:config-method: method 1 (writable symlink) -- repo changes take effect without rebuild.
  home.activation.seed-iterm2-dynamic-profiles = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
    "${activationBundle}/src/scripts/configs/seed-writable-symlink.sh" \
      "${config.home.homeDirectory}/Library/Application Support/iTerm2/DynamicProfiles" \
      "${overlay.toRepoRelPath iterm2DynamicProfilesDir}" \
  '';

  # Source iTerm2 shell integration when the script is present.  The test-e
  # guard makes this a no-op in non-iTerm2 terminals (VS Code terminal, SSH,
  # Ghostty, etc.) where the iTerm2 escape sequences produce no useful output
  # and may be visible as raw control codes.
  programs.zsh.initContent = ''
    test -e "$HOME/.iterm2_shell_integration.zsh" && source "$HOME/.iterm2_shell_integration.zsh"
  '';
}
