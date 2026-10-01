# iTerm2 configuration: shell integration script, Dynamic Profiles symlink, and
# the zsh sourcing guard. NSUserDefaults keys live in hosts/MacBook/defaults.nix
# (darwin context, where CustomUserPreferences is available).
# macOS-only; no NixOS or Windows equivalent.
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

  # Pinned iTerm2 zsh shell integration script. Enables command marks, history,
  # directory reporting, and in-terminal images in iTerm2 sessions. Update the
  # hash when iTerm2 publishes a new revision:
  #   nix-prefetch-url https://iterm2.com/shell_integration/zsh
  iterm2ZshIntegration = pkgs.fetchurl {
    url = "https://iterm2.com/shell_integration/zsh";
    sha256 = "0yhfnaigim95sk1idrc3hpwii8hfhjl5m3lyc0ip3vi1a9npq0li";
  };
  # Root of the nucleus repository, set by apply.sh at activation time.

  overlay = (import ./lib/users-overlay.nix { inherit lib; }).mkUserOverlay {
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

  # Writable symlink to the Dynamic Profiles directory, created against the LIVE
  # repo root so profile edits take effect without a rebuild. Runs before
  # protect-out-of-store-symlinks so the link gets hardened.
  # check-suppress:config-method: method 1 (writable symlink) -- repo changes take effect without rebuild.
  home.activation.seed-iterm2-dynamic-profiles = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
    "${activationBundle}/src/scripts/configs/seed-writable-symlink.sh" \
      "${config.home.homeDirectory}/Library/Application Support/iTerm2/DynamicProfiles" \
      "${overlay.toRepoRelPath iterm2DynamicProfilesDir}" \
  '';

  # The test-e guard keeps this a no-op outside iTerm2 (VS Code terminal, SSH,
  # Ghostty), where the escape sequences show up as raw control codes.
  programs.zsh.initContent = ''
    test -e "$HOME/.iterm2_shell_integration.zsh" && source "$HOME/.iterm2_shell_integration.zsh"
  '';
}
