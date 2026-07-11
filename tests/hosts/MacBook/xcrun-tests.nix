# tests/hosts/MacBook/xcrun-tests.nix — Regression tests for xcrun-free
# compiler resolution on macOS.
#
# Verifies that:
#   1. CC/CXX/LD in shell/env.nix are absolute Nix store paths (not bare
#      names that could resolve to /usr/bin/clang -> xcrun).
#   2. ntfs-3g.nix includes llvmPackages.clang in the activation build path
#      and exports absolute store paths for CC/CXX before ./configure.
#
# The old bare-format (CC = "clang") caused the xcrun dialog on macOS when
# subprocesses resolved the name outside a Nix build environment. These
# assertions guard against regression.

let
  lib = import <nixpkgs/lib>;

  envNix = builtins.readFile ../../../src/modules/shell/env.nix;
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
