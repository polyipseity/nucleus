# tests/modules/git-lfs-filter-tests.nix: Guard the machine-wide LFS filters.
#
# A text check is allowed here under all four conditions in
# testing.instructions.md: no runtime exists to test against, the match anchors
# to INI section and key lines rather than prose, a failure names the template
# and the part that drifted, and no other check reads these files.

let
  inherit (import ../lib.nix) assert';
  lib = import <nixpkgs/lib>;

  repoRoot = ../..;
  hosts = [
    "MacBook"
    "NixOS"
    "Windows"
  ];

  sectionHeader = "[filter \"lfs\"]";

  # The four keys git lfs install writes, from git-lfs lfs/attribute.go
  # (filterAttribute) and docs/man/git-lfs-install.adoc.
  keys = [
    "clean = git-lfs clean -- %f"
    "smudge = git-lfs smudge -- %f"
    "process = git-lfs filter-process"
    "required = true"
  ];

  templateLines =
    host:
    map lib.strings.trim (
      lib.strings.splitString "\n" (
        builtins.readFile (repoRoot + "/src/modules/configs/git/${host}.gitconfig")
      )
    );

  isSectionHeader = line: lib.strings.hasPrefix "[" line;

  # Body of the filter.lfs section: the lines after its header, up to the next
  # section header, blank lines dropped. Anchoring to the boundaries is what
  # rejects a key that sits in another section or a second copy of the block.
  sectionBody =
    lines: index:
    let
      rest = lib.lists.drop (index + 1) lines;
      nextHeaders = builtins.filter (i: isSectionHeader (builtins.elemAt rest i)) (
        lib.lists.range 0 (builtins.length rest - 1)
      );
      length = if nextHeaders == [ ] then builtins.length rest else builtins.head nextHeaders;
    in
    builtins.filter (line: line != "") (lib.lists.sublist 0 length rest);

  problemsFor =
    host:
    let
      lines = templateLines host;
      indexes = lib.lists.range 0 (builtins.length lines - 1);
      headerIndexes = builtins.filter (i: builtins.elemAt lines i == sectionHeader) indexes;
      body = if headerIndexes == [ ] then [ ] else sectionBody lines (builtins.head headerIndexes);
      headerProblems =
        if headerIndexes == [ ] then
          [ "no ${sectionHeader} section" ]
        else if builtins.length headerIndexes > 1 then
          [ "${sectionHeader} appears ${toString (builtins.length headerIndexes)} times" ]
        else
          [ ];
      keyProblems = map (
        key:
        "key line '${key}' appears ${
          toString (lib.lists.count (line: line == key) body)
        } times in the ${sectionHeader} section"
      ) (builtins.filter (key: lib.lists.count (line: line == key) body != 1) keys);
    in
    headerProblems ++ keyProblems;

  checkHost =
    host:
    let
      problems = problemsFor host;
    in
    assert' (
      problems == [ ]
    ) "src/modules/configs/git/${host}.gitconfig: ${lib.strings.concatStringsSep "; " problems}";

  tests = map checkHost hosts;
in
builtins.seq (builtins.deepSeq tests null) { success = true; }
