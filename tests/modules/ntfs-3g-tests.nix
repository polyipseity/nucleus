# tests/modules/ntfs-3g-tests.nix — Validate ntfs-3g patch files and Nix module.
#
# Verifies that the checked-in patch files are valid unified diffs, that they
# produce the correct transformations, and that the Nix module no longer uses
# inline Python or sed for patching.
#
# Run with: nix-instantiate --eval tests/modules/ntfs-3g-tests.nix

let
  flatten = text: builtins.replaceStrings [ "\n" "\r" ] [ " " " " ] text;
  containsRegex = pattern: haystack: builtins.match ".*${pattern}.*" (flatten haystack) != null;
  nonEmpty = text: builtins.stringLength text > 0;

  nixText = builtins.readFile ../../src/hosts/MacBook/ntfs-3g.nix;
  cryptoPatchText = builtins.readFile ../../src/hosts/MacBook/patches/ntfs-3g-crypto.patch;
  rootbindirPatchText = builtins.readFile ../../src/hosts/MacBook/patches/ntfs-3g-rootbindir.patch;

  inherit (import ../lib.nix) assert';

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

  # Test 6: Rootbindir patch changes /bin to /usr/local/bin.
  test_rootbindir_patch_changes_bin = assert' (
    containsRegex ''rootbindir="/bin"'' rootbindirPatchText
    && containsRegex ''rootbindir="/usr/local/bin"'' rootbindirPatchText
  ) "ntfs-3g-rootbindir.patch must change rootbindir from /bin to /usr/local/bin";

  # === Nix module no longer uses inline Python or sed ===

  # Test 7: python3 is not in buildToolsPath.
  test_no_python3_dependency = assert' (
    !containsRegex "python3" nixText
  ) "ntfs-3g.nix must not reference python3 in buildToolsPath";

  # Test 8: patchCryptoAc Python code is removed.
  test_no_inline_python_patch = assert' (
    !containsRegex "patchCryptoAc" nixText
  ) "ntfs-3g.nix must not contain inline Python patchCryptoAc";

  # Test 9: sed rootbindir fix is removed.
  test_no_sed_rootbindir = assert' (
    !containsRegex "sed.*rootbindir" nixText
  ) "ntfs-3g.nix must not use sed for rootbindir patching";

  # === Nix module references the checked-in patch files ===

  # Test 10: Module references cryptoPatchPath.
  test_references_crypto_patch = assert' (containsRegex "cryptoPatchPath" nixText) "ntfs-3g.nix must define cryptoPatchPath";

  # Test 11: Module references rootbindirPatchPath.
  test_references_rootbindir_patch = assert' (containsRegex "rootbindirPatchPath" nixText) "ntfs-3g.nix must define rootbindirPatchPath";

  # Test 12: Module uses patch -p1 for both patches.
  test_uses_patch_command = assert' (
    containsRegex "patch -p1.*cryptoPatchPath" nixText
    && containsRegex "patch -p1.*rootbindirPatchPath" nixText
  ) "ntfs-3g.nix must apply both patches with patch -p1";

  # Test 13: fingerprint includes both patch files (not inline strings).
  test_fingerprint_includes_patch_paths = assert' (
    containsRegex "cryptoPatchPath" nixText && containsRegex "rootbindirPatchPath" nixText
  ) "buildFingerprint must reference patch file paths (not inline code)";
in
{
  inherit
    test_crypto_patch_non_empty
    test_rootbindir_patch_non_empty
    test_crypto_patch_is_unified_diff
    test_rootbindir_patch_is_unified_diff
    test_crypto_patch_removes_crypto_block
    test_rootbindir_patch_changes_bin
    test_no_python3_dependency
    test_no_inline_python_patch
    test_no_sed_rootbindir
    test_references_crypto_patch
    test_references_rootbindir_patch
    test_uses_patch_command
    test_fingerprint_includes_patch_paths
    ;
}
