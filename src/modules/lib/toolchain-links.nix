# modules/lib/toolchain-links.nix: Stable SYSTEM-root symlinks for every
# toolchain path the env catalog exports.
#
# WHY this exists: the env catalog used to export raw /nix/store paths (CC,
# DEVELOPER_DIR, SDKROOT, and friends). A rebuild re-keys those derivations and
# `nix-collect-garbage` frees the old ones, so every long-lived shell, tmux pane,
# and GUI process that inherited the old value points at a path that no longer
# exists. The exported value instead names a stable symlink under the host
# SYSTEM root (`<root>/toolchains/<name>`) that activation repoints each apply,
# so GC can never invalidate an exported value. The derivations are interpolated
# by the activation module, which keeps them in the system closure for as long
# as the links point at them.
#
# Pure function, not a module: call with `lib` + `pkgs`.
{ lib, pkgs }:
let
  appleSdkEnhanced = import ./apple-sdk-enhanced.nix { inherit pkgs lib; };

  # WHY a host-NAME map instead of `nucleus-roots.nix`'s pkgs-derived
  # `nucleusSystemRoot`: the catalog resolves all three hosts' values inside a
  # single evaluation (toJsonManifest materialises MacBook, NixOS, and Windows
  # values together), and `nucleusSystemRoot` only knows the CURRENT eval's
  # platform. A per-host-name literal is the only shape that yields the other
  # host's path from one eval. These two roots are the SYSTEM roots documented in
  # nucleus-roots.nix and AGENTS.md.
  systemRootFor =
    host:
    if host == "MacBook" then
      "/Library/Application Support/nucleus"
    else if host == "NixOS" then
      "/var/lib/nucleus"
    else
      null;

  linkDirFor =
    host:
    let
      root = systemRootFor host;
    in
    if root == null then null else "${root}/toolchains";

  # Link name -> store derivation, per host. Only names listed here are
  # converged into <linkdir>; anything else found there is stale and removed.
  #
  # The shared set covers both POSIX hosts. apple-sdk and libiconv are macOS-only
  # (matching the catalog's MacBook-only DEVELOPER_DIR/SDKROOT/LIBRARY_PATH), and
  # a host outside POSIX gets no links at all: Windows exports bare tool names
  # and has no Nix store.
  sharedTargets = {
    cacert = pkgs.cacert;
    clang = pkgs.llvmPackages.clang;
    lld = pkgs.lld;
    playwright-browsers = pkgs.playwright-driver.browsers;
    sccache = pkgs.sccache;
  };

  macTargets = {
    inherit (sharedTargets)
      cacert
      clang
      lld
      playwright-browsers
      sccache
      ;
    apple-sdk = appleSdkEnhanced;
    libiconv = pkgs.libiconv;
  };

  linkTargetsFor =
    host:
    if host == "MacBook" then
      macTargets
    else if host == "NixOS" then
      sharedTargets
    else
      { };

in
{
  inherit linkDirFor linkTargetsFor systemRootFor;
}
