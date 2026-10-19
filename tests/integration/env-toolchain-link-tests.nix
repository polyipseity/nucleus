# tests/integration/env-toolchain-link-tests.nix: The env catalog must never
# export a raw /nix/store path on POSIX.
#
# Every POSIX toolchain value (CC, DEVELOPER_DIR, SDKROOT, ...) resolves to a
# stable symlink under the host SYSTEM root (`<root>/toolchains/<name>`) that
# activation repoints each apply, so `nix-collect-garbage` can never leave an
# inherited value dangling. This asserts that contract at the catalog level for
# both POSIX hosts: no resolved value names the store directly, and every value
# that routes through `toolchains/` names a link the host actually declares.
#
# The catalog is fully pkgs-independent after the reroute (only literal roots and
# username/home interpolation remain), so it evaluates identically on any host
# platform: no darwin package set is needed to check the MacBook values.
#
# Run with: nix-instantiate --eval --strict tests/integration/env-toolchain-link-tests.nix
let
  inherit (import ../lib.nix) assert';

  lib = import <nixpkgs/lib>;
  pkgs = import <nixpkgs> { };
  config = { };

  toolchainLinks = import ../../src/modules/lib/toolchain-links.nix { inherit lib pkgs; };

  posixHosts = [
    "MacBook"
    "NixOS"
  ];

  posixHostsText = builtins.concatStringsSep ", " posixHosts;

  mkEnv =
    hostName:
    import ../../src/modules/lib/env-secrets.nix {
      inherit
        config
        pkgs
        lib
        hostName
        ;
      username = "test";
    };

  # Every catalog var that resolves to a non-null value for the host.
  resolvedFor =
    host:
    let
      env = mkEnv host;
      pairs = builtins.map (name: {
        inherit name;
        value = env.resolveValue name host;
      }) env.getAllNixVarNames;
    in
    builtins.filter (p: p.value != null) pairs;

  hasStore = value: lib.hasInfix "/nix/store" value;

  # The link name is the first path segment after `/toolchains/`.
  linkNameOf =
    value:
    let
      parts = lib.splitString "/toolchains/" value;
      segments = lib.splitString "/" (builtins.elemAt parts 1);
    in
    if builtins.length parts >= 2 then builtins.head segments else null;

  toolchainValues = host: builtins.filter (p: lib.hasInfix "/toolchains/" p.value) (resolvedFor host);

  declaredLinks = host: builtins.attrNames (toolchainLinks.linkTargetsFor host);

  storeLeakNames =
    host: builtins.map (p: p.name) (builtins.filter (p: hasStore p.value) (resolvedFor host));

  undeclaredLinkNames =
    host:
    builtins.map (p: p.name) (
      builtins.filter (p: !(builtins.elem (linkNameOf p.value) (declaredLinks host))) (
        toolchainValues host
      )
    );

  expectedLinkDir =
    host:
    if host == "MacBook" then
      "/Library/Application Support/nucleus/toolchains"
    else
      "/var/lib/nucleus/toolchains";

  # Per-host applicability is discriminating: the macOS-only links must exist on
  # MacBook and be absent on NixOS, so a flattened host map fails.
  applicabilityTests =
    host:
    if host == "MacBook" then
      [
        (assert' (builtins.elem "apple-sdk" (declaredLinks host)) "MacBook must declare the apple-sdk link")
        (assert' (builtins.elem "libiconv" (declaredLinks host)) "MacBook must declare the libiconv link")
      ]
    else
      [
        (assert' (
          !(builtins.elem "apple-sdk" (declaredLinks host))
        ) "NixOS must not declare the macOS-only apple-sdk link")
        (assert' (
          !(builtins.elem "libiconv" (declaredLinks host))
        ) "NixOS must not declare the macOS-only libiconv link")
      ];

  hostTests =
    host:
    [
      # Invariant 1: no resolved value names the store directly.
      (assert' (
        storeLeakNames host == [ ]
      ) "${host}: catalog values leak /nix/store: ${builtins.toJSON (storeLeakNames host)}")
      # Invariant 2: every toolchains/-routed value names a link this host declares.
      (assert' (undeclaredLinkNames host == [ ])
        "${host}: toolchain values name an undeclared link: ${builtins.toJSON (undeclaredLinkNames host)}"
      )
      # The SYSTEM root is host-keyed, so a swapped root fails here.
      (assert' (
        toolchainLinks.linkDirFor host == expectedLinkDir host
      ) "${host}: linkDirFor must map to the host SYSTEM root")
    ]
    ++ applicabilityTests host;

  tests = lib.concatMap hostTests posixHosts;
in
{
  # deepSeq forces every assertion when `success` is evaluated, so the suite
  # cannot report green while skipping a check (Nix is lazy).
  success = builtins.deepSeq tests true;
  message = "env toolchain-link invariant tests passed for ${posixHostsText}";
}
