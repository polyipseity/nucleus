# iTerm2 terminal emulator configuration.
#
# Houses all iTerm2-specific settings: NSUserDefaults keys (written via
# nix-darwin's system.defaults.CustomUserPreferences), shell integration
# script, and zsh initContent sourcing guard.
#
# Source: https://iterm2.com/documentation.html
{
  config,
  lib,
  pkgs,
  ...
}:
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
in
lib.mkIf pkgs.stdenv.isDarwin {
  # ---------------------------------------------------------------------------
  # NSUserDefaults keys written to the com.googlecode.iterm2 domain.
  # These control app-level preferences (not per-profile settings).
  # ---------------------------------------------------------------------------
  system.defaults.CustomUserPreferences."com.googlecode.iterm2" = {
    # Allow clipboard access from terminal applications.
    "AllowClipboardAccess" = true;
    # Bootstrap daemon: supports shell integration without requiring a full
    # app launch.
    "BootstrapDaemon" = true;
    # Enable "Open in iTerm" Finder right-click context menu.
    "EnableFindersService" = true;
    # Pre-answer the first-launch "may we show you tips?" permission prompt
    # so iTerm2 skips that dialog on a fresh provision and goes straight to
    # showing tips.  Simulates the state where the user already answered yes.
    "NoSyncPermissionToShowTip" = true;
    "NoSyncTipOfTheDay" = true;
    # Blocks other processes from reading keystrokes.
    "Secure Input" = true;
    # Disable in-app update checks; updates are managed declaratively.
    "SUCheckAtStartup" = false;
    "SUEnableAutomaticChecks" = false;
    # Suppress the "Warn about short-lived sessions" dialog for each profile.
    # The NeverWarnAboutShortLivedSessions_<GUID> key silences the iTermWarning
    # that fires when a session ends within shortLivedSessionDuration (default 3s).
    # Source: PTYSession.m _maybeWarnAboutShortLivedSessions
    "NeverWarnAboutShortLivedSessions_743F1344-118A-4E38-8CB0-D7319D34EF8C" = true;
    # Suppress the secure-keyboard-entry warning when opening a command.
    "WarnAboutSecureKeyboardInputWithOpenCommand" = false;
  };

  home.file = {
    # Place the pinned iTerm2 zsh shell integration script at the well-known
    # path that the sourcing guard in programs.zsh.initContent expects.
    # home.file replaces the symlink atomically on each home-manager switch so
    # the script version tracks the pinned hash in iterm2ZshIntegration above.
    ".iterm2_shell_integration.zsh".source = iterm2ZshIntegration;
  };

  # Source iTerm2 shell integration when the script is present.  The test-e
  # guard makes this a no-op in non-iTerm2 terminals (VS Code terminal, SSH,
  # Ghostty, etc.) where the iTerm2 escape sequences produce no useful output
  # and may be visible as raw control codes.
  programs.zsh.initContent = ''
    test -e "$HOME/.iterm2_shell_integration.zsh" && source "$HOME/.iterm2_shell_integration.zsh"
  '';
}
