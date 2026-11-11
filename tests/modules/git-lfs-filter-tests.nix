# tests/modules/git-lfs-filter-tests.nix: Guard the machine-wide LFS filters.
#
# A text check is allowed here under all four conditions in
# testing.instructions.md: no runtime exists to test against, the match anchors
# to INI section and key lines rather than prose, a failure names the template
# that drifted, and no other check reads these files.

let
  inherit (import ../lib.nix) assert' all;
  lib = import <nixpkgs/lib>;

  repoRoot = ../..;
  hosts = [
    "MacBook"
    "NixOS"
    "Windows"
  ];

  template = host: builtins.readFile (repoRoot + "/src/modules/configs/git/${host}.gitconfig");

  # The four keys git lfs install writes, from git-lfs lfs/attribute.go
  # (filterAttribute) and docs/man/git-lfs-install.adoc.
  lines = [
    "[filter \"lfs\"]"
    "clean = git-lfs clean -- %f"
    "smudge = git-lfs smudge -- %f"
    "process = git-lfs filter-process"
    "required = true"
  ];

  checkHost =
    host:
    assert' (all (line: lib.hasInfix line (template host))
      lines
    ) "src/modules/configs/git/${host}.gitconfig is missing part of the machine-wide filter.lfs block";

  tests = map checkHost hosts;
in
builtins.seq (builtins.deepSeq tests null) { success = true; }
