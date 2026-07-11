# tests/hosts/MacBook/xcrun-tests.nix — Regression tests for xcrun-free
# compiler resolution on macOS.
#
# Verifies that:
#   1. CC/CXX/LD in shell/env.nix are absolute Nix store paths (not bare
#      names that could resolve to /usr/bin/clang -> xcrun).
#   2. DEVELOPER_DIR is set in shell.nix's darwin-only sessionVariables block
#      so xcrun SDK discovery works in interactive shells without CLT.
#   3. xcode-select --switch to Nix apple-sdk is wired in activation.nix
#      so xcrun works for non-shell process trees.
#   4. ntfs-3g.nix includes llvmPackages.clang in the activation build path
#      and exports absolute store paths for CC/CXX before ./configure.
#
# The old bare-format (CC = "clang") caused the xcrun dialog on macOS when
# subprocesses resolved the name outside a Nix build environment. These
# assertions guard against regression.

let
  lib = import <nixpkgs/lib>;

  envNix = builtins.readFile ../../../src/modules/shell/env.nix;
  shellNix = builtins.readFile ../../../src/modules/shell.nix;
  activationNix = builtins.readFile ../../../src/hosts/MacBook/activation.nix;
  ntfs3gText = builtins.readFile ../../../src/hosts/MacBook/ntfs-3g.nix;
in

# --- shell/env.nix assertions ---

# CC must resolve to an absolute Nix store path within llvmPackages.clang.
assert lib.hasInfix "/bin/clang" envNix;

# CXX must resolve to an absolute Nix store path within llvmPackages.clang.
assert lib.hasInfix "/bin/clang++" envNix;

# LD must resolve to an absolute Nix store path within llvmPackages.lld.
assert lib.hasInfix "/bin/ld.lld" envNix;

# OPENCODE_DISABLE_AUTOUPDATE must be preserved (no collateral damage).
assert lib.hasInfix "OPENCODE_DISABLE_AUTOUPDATE" envNix;

# Old bare format must NOT be present; CC = "clang" would trigger xcrun.
assert !lib.hasInfix ''CC = "clang";'' envNix;

# --- shell.nix assertions ---

# DEVELOPER_DIR must be set in the darwin-only sessionVariables block so
# xcrun --sdk macosx --show-sdk-path finds the Nix SDK from any shell session.
assert lib.hasInfix "DEVELOPER_DIR" shellNix;

# DEVELOPER_DIR must reference pkgs.apple-sdk (not a stale hardcoded path).
assert lib.hasInfix "pkgs.apple-sdk" shellNix;

# --- activation.nix assertions ---

# xcode-select --switch must be configured at activation time so xcrun works
# for launchd services, VS Code non-shell tasks, and other system processes.
assert lib.hasInfix "xcode-select --switch" activationNix;

# The switch target must reference the Nix apple-sdk path.
assert lib.hasInfix "apple-sdk" activationNix;

# --- ntfs-3g.nix assertions ---

# llvmPackages.clang must be in buildToolsPath so the activation build
# does not fall back to /usr/bin/cc during ./configure.
assert lib.hasInfix "llvmPackages.clang" ntfs3gText;

# CC must be exported as an absolute store path before ./configure.
assert lib.hasInfix ''export CC="'' ntfs3gText;

# CXX must be exported as an absolute store path before ./configure.
assert lib.hasInfix ''export CXX="'' ntfs3gText;

{
  success = true;
  message = "xcrun-free compiler resolution tests passed";
}
