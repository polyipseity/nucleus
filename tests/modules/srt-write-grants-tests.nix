# tests/modules/srt-write-grants-tests.nix: sandbox write grants for root symlink targets.
#
# Seatbelt matches canonical paths, so sandboxed writes through <USER root>/state and
# <USER root>/logs must be granted on the physical link targets. The roots lib is the
# single source of truth for those targets and srt/settings.json must grant every one.

let
  inherit (import ../lib.nix) assert';

  srtSettings = builtins.fromJSON (builtins.readFile ../../src/users/default/srt/settings.json);
  allowWrite = srtSettings.filesystem.allowWrite;

  libStub = {
    concatStringsSep = sep: list: builtins.concatStringsSep sep list;
    concatMapStringsSep =
      sep: f: list:
      builtins.concatStringsSep sep (map f list);
    optionalString = cond: str: if cond then str else "";
    unique = list: builtins.foldl' (acc: x: if builtins.elem x acc then acc else acc ++ [ x ]) [ ] list;
  };

  mkRoots =
    isDarwin:
    let
      pkgs = {
        stdenv.hostPlatform.isDarwin = isDarwin;
      };
    in
    import ../../src/modules/lib/nucleus-roots.nix {
      lib = libStub;
      pkgs = pkgs;
    };

  darwinRoots = mkRoots true;
  linuxRoots = mkRoots false;

  darwinTargets = darwinRoots.userLinkTargetsFor "/Users/testuser";
  linuxTargets = linuxRoots.userLinkTargetsFor "/home/testuser";

  targetValues = targets: builtins.attrValues targets;

  allUserLinkTargets = targetValues darwinTargets ++ targetValues linuxTargets;

  # SRT settings use ~ for the user home. Rewrite absolute homes to ~ so grants and
  # exported targets compare in the same form.
  libHasPrefix = prefix: str: builtins.substring 0 (builtins.stringLength prefix) str == prefix;

  toGrantPath =
    path:
    let
      darwinPrefix = "/Users/testuser";
      linuxPrefix = "/home/testuser";
    in
    if libHasPrefix darwinPrefix path then
      "~" + builtins.substring (builtins.stringLength darwinPrefix) (builtins.stringLength path) path
    else if libHasPrefix linuxPrefix path then
      "~" + builtins.substring (builtins.stringLength linuxPrefix) (builtins.stringLength path) path
    else
      path;

  allGrantPaths = map toGrantPath allUserLinkTargets;

  missingGrants = builtins.filter (grantPath: !(builtins.elem grantPath allowWrite)) allGrantPaths;

  test_darwin_targets_exported = assert' (
    darwinTargets.logs == "/Users/testuser/Library/Logs/nucleus"
    && darwinTargets.state == "/Users/testuser/Library/State/nucleus"
  ) "darwin user link targets must export logs and state canonical directories";

  test_nixos_targets_exported = assert' (
    linuxTargets.logs == "/home/testuser/.local/state/nucleus/log"
    && !(builtins.hasAttr "state" linuxTargets)
  ) "NixOS user link targets must export logs only (state is a real dir under user root)";

  test_all_user_link_targets_granted =
    assert' (missingGrants == [ ])
      "every user link target must be present in srt filesystem.allowWrite, missing: ${builtins.toJSON missingGrants}";

  test_grants_present_explicitly = assert' (
    builtins.elem "~/.local/state/nucleus/log" allowWrite
    && builtins.elem "~/Library/Logs/nucleus" allowWrite
    && builtins.elem "~/Library/State/nucleus" allowWrite
  ) "srt allowWrite must include macOS and NixOS user link targets";

  allTests = [
    test_darwin_targets_exported
    test_nixos_targets_exported
    test_all_user_link_targets_granted
    test_grants_present_explicitly
  ];
in
builtins.seq (builtins.deepSeq allTests null) {
  success = true;
  testCount = builtins.length allTests;
  message = "All ${toString (builtins.length allTests)} srt-write-grants tests passed";
}
