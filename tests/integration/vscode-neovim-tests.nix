# tests/integration/vscode-neovim-tests.nix — Verify vscode-neovim extension provisioning.

let
  lib = import <nixpkgs/lib>;
  inherit (import ../lib.nix) assert';

  editorsText = builtins.readFile ../../src/modules/editors.nix;
  windowsExtensionsText = builtins.readFile ../../src/hosts/Windows/modules/editors/Sync-VSCodeExtensionManifest.ps1;
  lockfileText = builtins.readFile ../../src/lockfiles/lockfile.json;
  settingsText = builtins.readFile ../../src/users/default/vscode/settings.json;
  macosDefaultsText = builtins.readFile ../../src/hosts/MacBook/defaults.nix;
  macosActivationText = builtins.readFile ../../src/hosts/MacBook/activation.nix;

  test_extension_in_editors_nix = assert' (lib.hasInfix "asvetliakov.vscode-neovim" editorsText) "editors.nix must list asvetliakov.vscode-neovim in sharedExtensions";

  test_extension_in_windows_ps1 = assert' (lib.hasInfix "asvetliakov.vscode-neovim" windowsExtensionsText) "Sync-VSCodeExtensionManifest.ps1 must list asvetliakov.vscode-neovim in managedExtensions";

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

  test_neovim_launcher_symlink = assert' (
    lib.hasInfix "launch-nvim.sh" macosActivationText
    && lib.hasInfix "/etc/nucleus/bin/nvim" (builtins.readFile ../../src/scripts/editors/launch-nvim.sh)
  ) "launch-nvim.sh must create /etc/nucleus/bin/nvim and MacBook activation.nix must invoke it";

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
        && lib.hasInfix "/etc/nucleus/bin/nvim" settingsText
        && !lib.hasInfix "vscode-neovim.neovimExecutablePaths.win32" settingsText
      )
      "settings.json must have vscode-neovim neovimExecutablePaths with /etc/nucleus/bin/nvim for darwin/linux and no win32 entry";
in
builtins.seq
  (builtins.deepSeq {
    inherit
      test_extension_in_editors_nix
      test_extension_in_windows_ps1
      test_extension_in_lockfile
      test_vscode_conditional_in_init_lua
      test_jk_mapping_in_init_lua
      test_keyrepeat_in_macos_defaults
      test_neovim_launcher_symlink
      test_editor_line_numbers_in_settings
      test_scroll_beyond_last_line_in_settings
      test_composite_keys_in_settings
      test_neovim_executable_paths_in_settings
      ;
  })
  {
    success = true;
    testCount = 11;
    message = "All 11 vscode-neovim tests passed";
  }
