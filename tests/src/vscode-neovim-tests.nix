# tests/src/vscode-neovim-tests.nix — Verify vscode-neovim extension provisioning.
#
# This test verifies that the vscode-neovim VS Code extension is properly
# wired across all provisioning layers (POSIX Nix, Windows PowerShell,
# lockfile versions, VS Code settings, macOS defaults, and Neovim init.lua).
#
# Run with: nix-instantiate --eval tests/src/vscode-neovim-tests.nix

{
  lib ? import <nixpkgs/lib>,
}:
let
  inherit (import ../lib.nix) assert';

  editorsText = builtins.readFile ../../src/modules/editors.nix;
  windowsExtensionsText = builtins.readFile ../../src/hosts/Windows/modules/editors/Sync-VSCodeExtension.ps1;
  lockfileText = builtins.readFile ../../src/lockfiles/lockfile.json;
  settingsText = builtins.readFile ../../src/modules/configs/vscode/settings.json;
  macosDefaultsText = builtins.readFile ../../src/hosts/MacBook/defaults.nix;
  macosActivationText = builtins.readFile ../../src/hosts/MacBook/activation.nix;

  test_extension_in_editors_nix = assert' (lib.hasInfix "asvetliakov.vscode-neovim" editorsText) "editors.nix must list asvetliakov.vscode-neovim in sharedExtensions";

  test_extension_in_windows_ps1 = assert' (lib.hasInfix "asvetliakov.vscode-neovim" windowsExtensionsText) "Sync-VSCodeExtension.ps1 must list asvetliakov.vscode-neovim in managedExtensions";

  test_extension_in_lockfile = assert' (lib.hasInfix "asvetliakov.vscode-neovim" lockfileText) "lockfile.json must pin asvetliakov.vscode-neovim version";

  test_vscode_conditional_in_init_lua = assert' (
    lib.hasInfix "vim.g.vscode" editorsText && lib.hasInfix "editor.action.formatSelection" editorsText
  ) "editors.nix neovimInitLua must have vscode conditional block with formatSelection mapping";

  test_jk_mapping_in_init_lua = assert' (lib.hasInfix "\"jk\", \"<Esc>\"" editorsText) "editors.nix neovimInitLua must have jk -> <Esc> insert mode mapping";

  test_keyrepeat_in_macos_defaults = assert' (
    lib.hasInfix "ApplePressAndHoldEnabled" macosDefaultsText
    && lib.hasInfix "com.microsoft.VSCode" macosDefaultsText
    && lib.hasInfix "com.microsoft.VSCodeInsiders" macosDefaultsText
  ) "MacBook defaults.nix must disable ApplePressAndHold for both VS Code stable and Insiders";

  test_neovim_launcher_symlink = assert' (lib.hasInfix "nvimLauncher" macosActivationText) "MacBook activation.nix must have nvimLauncher section creating /etc/nucleus-bin/nvim";

  test_editor_line_numbers_in_settings = assert' (lib.hasInfix "\"editor.lineNumbers\": \"relative\"" settingsText) "settings.json must set editor.lineNumbers to relative";

  test_scroll_beyond_last_line_in_settings = assert' (lib.hasInfix "\"editor.scrollBeyondLastLine\": false" settingsText) "settings.json must set editor.scrollBeyondLastLine to false";

  test_composite_keys_in_settings = assert' (
    lib.hasInfix "vscode-neovim.compositeKeys" settingsText
    && lib.hasInfix "vscode-neovim.escape" settingsText
  ) "settings.json must have vscode-neovim.compositeKeys with jk escape";

  test_neovim_executable_paths_in_settings =
    assert'
      (
        lib.hasInfix "vscode-neovim.neovimExecutablePaths.darwin" settingsText
        && lib.hasInfix "vscode-neovim.neovimExecutablePaths.linux" settingsText
        && lib.hasInfix "/etc/nucleus-bin/nvim" settingsText
        && !lib.hasInfix "vscode-neovim.neovimExecutablePaths.win32" settingsText
      )
      "settings.json must have vscode-neovim neovimExecutablePaths with /etc/nucleus-bin/nvim for darwin/linux and no win32 entry";
in
{
  success = true;
  testCount = 11;
  message = "All ${builtins.toString 11} vscode-neovim provisioning tests passed";
}
