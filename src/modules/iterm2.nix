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
{ lib, pkgs, ... }:
let
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
  repoRoot = builtins.getEnv "NUCLEUS_REPO_ROOT";
in
lib.mkIf pkgs.stdenv.isDarwin {
  home.file = {
    # Place the pinned iTerm2 zsh shell integration script at the well-known
    # path that the sourcing guard in programs.zsh.initContent expects.
    # home.file replaces the symlink atomically on each home-manager switch so
    # the script version tracks the pinned hash in iterm2ZshIntegration above.
    ".iterm2_shell_integration.zsh".source = iterm2ZshIntegration;

    # Symlink the Dynamic Profiles directory so iTerm2 picks up profile
    # definitions at runtime.  iTerm2 monitors this directory for changes.
    # Method 1 (writable symlink) via config.lib.file.mkOutOfStoreSymlink.
    # See .agents/instructions/app-config-policy.instructions.md
    "Library/Application Support/iTerm2/DynamicProfiles".source =
      config.lib.file.mkOutOfStoreSymlink "${repoRoot}/src/modules/configs/iterm2/DynamicProfiles";
  };

  # Source iTerm2 shell integration when the script is present.  The test-e
  # guard makes this a no-op in non-iTerm2 terminals (VS Code terminal, SSH,
  # Ghostty, etc.) where the iTerm2 escape sequences produce no useful output
  # and may be visible as raw control codes.
  programs.zsh.initContent = ''
    test -e "$HOME/.iterm2_shell_integration.zsh" && source "$HOME/.iterm2_shell_integration.zsh"
  '';
}
