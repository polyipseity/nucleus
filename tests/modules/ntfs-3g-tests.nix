# tests/modules/ntfs-3g-tests.nix — ntfs-3g patch files and Nix module.

let
  inherit (import ../lib.nix) assert' containsRegex;
  nonEmpty = text: builtins.stringLength text > 0;

  nixText = builtins.readFile ../../src/hosts/MacBook/ntfs-3g.nix;
  buildScriptText = builtins.readFile ../../src/scripts/hosts/MacBook/macos-build-ntfs3g.sh;
  cryptoPatchText = builtins.readFile ../../src/hosts/MacBook/patches/ntfs-3g-crypto.patch;
  rootbindirPatchText = builtins.readFile ../../src/hosts/MacBook/patches/ntfs-3g-rootbindir.patch;
  installHookPatchText = builtins.readFile ../../src/hosts/MacBook/patches/ntfs-3g-install-hook.patch;

  # === Patch file existence and validity ===

  # Test 1: Crypto patch file is non-empty.
  test_crypto_patch_non_empty = assert' (nonEmpty cryptoPatchText) "ntfs-3g-crypto.patch must not be empty";

  # Test 2: Rootbindir patch file is non-empty.
  test_rootbindir_patch_non_empty = assert' (nonEmpty rootbindirPatchText) "ntfs-3g-rootbindir.patch must not be empty";

  # Test 3: Crypto patch is a valid unified diff (starts with ---).
  test_crypto_patch_is_unified_diff = assert' (
    containsRegex "--- " cryptoPatchText && containsRegex "\\+\\+\\+ " cryptoPatchText
  ) "ntfs-3g-crypto.patch must start with unified diff headers";

  # Test 4: Rootbindir patch is a valid unified diff.
  test_rootbindir_patch_is_unified_diff = assert' (
    containsRegex "--- " rootbindirPatchText && containsRegex "\\+\\+\\+ " rootbindirPatchText
  ) "ntfs-3g-rootbindir.patch must start with unified diff headers";

  # === Patch content correctness ===

  # Test 5: Crypto patch removes the crypto autodetection block.
  test_crypto_patch_removes_crypto_block = assert' (
    containsRegex "Autodetect whether we can build crypto stuff" cryptoPatchText
    && containsRegex "ENABLE_CRYPTO" cryptoPatchText
    && containsRegex "AM_PATH_LIBGCRYPT" cryptoPatchText
    && containsRegex "PKG_CHECK_MODULES" cryptoPatchText
  ) "ntfs-3g-crypto.patch must remove the crypto autodetection block from configure.ac";

  # Test 6: Rootbindir patch changes /bin to /usr/local/bin and /lib to /usr/local/lib.
  test_rootbindir_patch_changes_bin =
    assert'
      (
        containsRegex ''rootbindir="/bin"'' rootbindirPatchText
        && containsRegex ''rootbindir="/usr/local/bin"'' rootbindirPatchText
        && containsRegex ''rootlibdir="/usr/local/lib"'' rootbindirPatchText
      )
      "ntfs-3g-rootbindir.patch must change rootbindir from /bin to /usr/local/bin and rootlibdir from /lib to /usr/local/lib";

  # === New patch: install-exec-hook ===

  # Test 6b: Install-hook patch file is non-empty.
  test_install_hook_patch_non_empty = assert' (nonEmpty installHookPatchText) "ntfs-3g-install-hook.patch must not be empty";

  # Test 6c: Install-hook patch is a valid unified diff.
  test_install_hook_patch_is_unified_diff = assert' (
    containsRegex "--- " installHookPatchText && containsRegex "\\+\\+\\+ " installHookPatchText
  ) "ntfs-3g-install-hook.patch must start with unified diff headers";

  # Test 6d: Install-hook patch fixes the glob failure by wrapping mv in a for loop.
  test_install_hook_patch_fixes_mv_glob = assert' (
    containsRegex "for f in" installHookPatchText && containsRegex "continue" installHookPatchText
  ) "ntfs-3g-install-hook.patch must wrap mv in a for loop with existence guard";

  # Test 6e: Install-hook patch still invokes mv inside the loop.
  test_install_hook_patch_references_mv = assert' (containsRegex "MV" installHookPatchText) "ntfs-3g-install-hook.patch must still perform the mv inside the loop";

  # === Nix module no longer uses inline Python or sed ===

  # Test 7: python3 is not in buildToolsPath.
  test_no_python3_dependency = assert' (
    !containsRegex "python3" nixText
  ) "ntfs-3g.nix must not reference python3 in buildToolsPath";

  # Test 8: patchCryptoAc Python code is removed.
  test_no_inline_python_patch = assert' (
    !containsRegex "patchCryptoAc" nixText
  ) "ntfs-3g.nix must not contain inline Python patchCryptoAc";

  # === Nix module references the checked-in patch files ===

  # Test 10: Module references cryptoPatchPath.
  test_references_crypto_patch = assert' (containsRegex "cryptoPatchPath" nixText) "ntfs-3g.nix must define cryptoPatchPath";

  # Test 11: Module references rootbindirPatchPath.
  test_references_rootbindir_patch = assert' (containsRegex "rootbindirPatchPath" nixText) "ntfs-3g.nix must define rootbindirPatchPath";

  # Test 12: Module uses patch -p1 for all patches.
  test_uses_patch_command = assert' (
    containsRegex "patch -p1.*CRYPTO_PATCH_PATH" buildScriptText
    && containsRegex "patch -p1.*ROOTBINDIR_PATCH_PATH" buildScriptText
    && containsRegex "patch -p1.*INSTALL_HOOK_PATCH_PATH" buildScriptText
  ) "macos-build-ntfs3g.sh must apply all patches with patch -p1";

  # Test 12b: Module references installHookPatchPath.
  test_references_install_hook_patch = assert' (containsRegex "installHookPatchPath" nixText) "ntfs-3g.nix must define installHookPatchPath";

  # Test 13: fingerprint includes all patch file paths (not inline strings).
  test_fingerprint_includes_patch_paths = assert' (
    containsRegex "cryptoPatchPath" nixText
    && containsRegex "rootbindirPatchPath" nixText
    && containsRegex "installHookPatchPath" nixText
    && containsRegex "sdkRoot" nixText
    && containsRegex "linkFlags" nixText
  ) "buildFingerprint must reference all patch file paths, sdkRoot, and linkFlags";

  # Test 13b: configure disables external reparse plugins (no libdl probe on Darwin).
  test_configure_disables_plugins = assert' (containsRegex "--disable-plugins" nixText) "ntfs-3g configureFlags must pass --disable-plugins";

  # Test 13c: build script receives eval-time SDKROOT and defers fuse-t link flags to make.
  test_build_script_sdk_and_link_flags = assert' (
    containsRegex "SDK_ROOT=" buildScriptText
    && containsRegex "LINK_FLAGS=" buildScriptText
    && containsRegex "export SDKROOT=" buildScriptText
    && containsRegex "LDFLAGS=" buildScriptText
    && containsRegex "export LDFLAGS=.*LINK_FLAGS" buildScriptText
  ) "macos-build-ntfs3g.sh must set SDKROOT from Nix and apply fuse-t LDFLAGS only for make";

  # === Build script structure: log capture and error handling ===

  # Test 14: Module defines LOG_FILE path to the system log directory.
  test_log_file_path_defined = assert' (containsRegex "LOG_FILE=\"/Users/Shared/nucleus/logs/ntfs-3g-build.log\"" buildScriptText) "macos-build-ntfs3g.sh must define LOG_FILE pointing to system log dir";

  # Test 15: Module creates the log directory before writing.
  test_log_dir_created = assert' (containsRegex "mkdir -p.*dirname.*LOG_FILE" buildScriptText) "macos-build-ntfs3g.sh must mkdir -p the log file directory";

  # Test 16: Build output is redirected to the log file (stdout+stderr).
  test_output_redirected_to_log = assert' (containsRegex ">>.*LOG_FILE.*2>&1" buildScriptText) "macos-build-ntfs3g.sh must redirect build output to LOG_FILE with stderr";

  # Test 17: Module sets up trap cleanup for BUILD_DIR.
  test_trap_cleanup = assert' (containsRegex "trap.*rm -rf.*BUILD_DIR.*EXIT" buildScriptText) "macos-build-ntfs3g.sh must trap EXIT to clean up BUILD_DIR";

  # Test 18: Module prints log path on successful build completion.
  test_log_path_on_success = assert' (containsRegex "build complete.*log at" buildScriptText) "macos-build-ntfs3g.sh must print log path on build success";

  # Test 19: Module prints log path on build failure and exits with error.
  test_log_path_on_failure = assert' (
    containsRegex "BUILD FAILED" buildScriptText
    && containsRegex "exit.*exit_code" buildScriptText
    && containsRegex "realpath.*LOG_FILE" buildScriptText
  ) "macos-build-ntfs3g.sh must print log path on build failure and exit with non-zero";

  # WHY: Test asserts that ntfs-3g.nix no longer uses or-true for spurious failure masking.
  # The or-true references in the assertion strings below are part of the test's regex/error message, not the tested code.
  test_no_make_k_or_true = assert' (
    !containsRegex "make -k install" nixText && !containsRegex "\\|\\| true" nixText
  ) "ntfs-3g.nix must not use make -k install or or-true to mask failures";

  # Test 21: Build-finished echo is not inside the exit-code-tracked brace group.
  # Regression check: previously `echo "=== finished ==="` was the last command in
  # the brace group, always returning 0 and masking build failures.
  test_finished_echo_not_masking_error =
    assert' (!containsRegex "make install[^}]*echo === ntfs-3g build finished[^}]*\\} >>" nixText)
      "ntfs-3g.nix must not have the build-finished echo inside the brace group whose exit code is tracked";

  # Test 22: Install-hook patch glob matches both .so and .dylib on macOS.
  test_install_hook_patch_glob_matches_any_ext = assert' (containsRegex "libntfs-3g\\.\\*" installHookPatchText) "ntfs-3g-install-hook.patch must use a glob that matches both .so and .dylib (not just .so)";
in
{
  inherit
    test_crypto_patch_non_empty
    test_rootbindir_patch_non_empty
    test_crypto_patch_is_unified_diff
    test_rootbindir_patch_is_unified_diff
    test_crypto_patch_removes_crypto_block
    test_rootbindir_patch_changes_bin
    test_install_hook_patch_non_empty
    test_install_hook_patch_is_unified_diff
    test_install_hook_patch_fixes_mv_glob
    test_install_hook_patch_references_mv
    test_no_python3_dependency
    test_no_inline_python_patch
    test_references_crypto_patch
    test_references_rootbindir_patch
    test_uses_patch_command
    test_references_install_hook_patch
    test_fingerprint_includes_patch_paths
    test_configure_disables_plugins
    test_build_script_sdk_and_link_flags
    test_log_file_path_defined
    test_log_dir_created
    test_output_redirected_to_log
    test_trap_cleanup
    test_log_path_on_success
    test_log_path_on_failure
    test_no_make_k_or_true
    test_finished_echo_not_masking_error
    test_install_hook_patch_glob_matches_any_ext
    ;
}
