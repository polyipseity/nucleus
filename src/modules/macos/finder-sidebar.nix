# modules/macos/finder-sidebar.nix — Finder sidebar favorites automation.
#
# Provides Nix-level helpers for deterministic Finder sidebar state via
# mysides.  Used by macos.nix activation hooks.
{ config, lib, ... }:
let
  # URI-encode a string for use in file:// URLs consumed by `mysides add`.
  # `mysides` expects properly encoded URIs; raw spaces cause silent failures.
  # Source: https://en.wikipedia.org/wiki/Percent-encoding
  # Uses nixpkgs lib.escapeURL (RFC 3986) then decodes structural characters
  # (: and /) back so file:// URIs remain valid.
  uriEncode = url: builtins.replaceStrings [ "%3A" "%2F" ] [ ":" "/" ] (lib.escapeURL url);

  # Single source of truth for managed Finder favorites and ordering.
  finderSidebarManagedFavorites = [
    {
      name = "Applications";
      url = uriEncode "file:///Applications";
    }
    {
      name = "Downloads";
      url = uriEncode "file://${config.home.homeDirectory}/Downloads";
    }
    {
      name = "data";
      url = uriEncode "file://${config.home.homeDirectory}/data";
    }
    {
      name = "dev";
      url = uriEncode "file://${config.home.homeDirectory}/dev";
    }
    {
      name = "Desktop";
      url = uriEncode "file://${config.home.homeDirectory}/Desktop";
    }
    {
      name = "Documents";
      url = uriEncode "file://${config.home.homeDirectory}/Documents";
    }
    {
      name = "Music";
      url = uriEncode "file://${config.home.homeDirectory}/Music";
    }
    {
      name = "Movies";
      url = uriEncode "file://${config.home.homeDirectory}/Movies";
    }
    {
      name = "Pictures";
      url = uriEncode "file://${config.home.homeDirectory}/Pictures";
    }
    {
      name = "virtual machines";
      url = uriEncode "file://${config.home.homeDirectory}/virtual machines";
    }
    {
      name = "clouds";
      url = uriEncode "file://${config.home.homeDirectory}/clouds";
    }
  ];
in
rec {
  # Number of managed favorites; used to scope the sidebar-order comparison
  # to the exact count of expected entries.
  finderSidebarManagedCount = builtins.length finderSidebarManagedFavorites;

  # Keep expected sidebar order derivable from the managed favorites list.
  finderSidebarExpectedOrder = builtins.concatStringsSep "|" (
    map (favorite: favorite.name) finderSidebarManagedFavorites
  );

  # Paths guaranteed by macOS to exist under $HOME — skip symlink guard.
  finderSidebarAlwaysExist = [
    "Applications"
    "Desktop"
    "Documents"
    "Downloads"
    "Music"
    "Movies"
    "Pictures"
  ];

  # Ensure directories referenced by managed Finder favorites exist before add.
  finderSidebarEnsureDirectoriesShell = builtins.concatStringsSep "\n" (
    map (
      favorite:
      let
        safeName = favorite.name;
      in
      if builtins.elem favorite.name finderSidebarAlwaysExist then
        "# ${favorite.name}: system-owned, always exists\nmkdir -p \"$HOME/${safeName}\""
      else
        "# ${favorite.name}: managed favorite — symlink-safe guard\nif [ ! -d \"$HOME/${safeName}\" ] && [ ! -L \"$HOME/${safeName}\" ]; then\n  mkdir -p \"$HOME/${safeName}\"\nfi"
    ) finderSidebarManagedFavorites
  );

  # Pre-remove managed favorites and default extras by name before any
  # `mysides list` call.  `mysides remove <name>` works by name lookup and
  # never needs to parse the sidebar list, so it safely removes corrupted
  # entries that would cause `mysides list` to segfault (e.g. bookmarks with
  # unexpanded literal `$HOME` URLs from a previous version of this config).
  #
  # Sources for default extras: ``/`` reappears after daemon restarts, the
  # user's home-directory alias shows up on new macOS versions, and `.Trash`
  # re-emerges on macOS upgrades.
  finderSidebarPreRemoveShell = ''
    ${builtins.concatStringsSep "\n" (
      map
        (favoriteName: ''"$MYSIDES_BIN" remove ${lib.escapeShellArg favoriteName} >/dev/null 2>&1 || true'')
        (
          (map (f: f.name) finderSidebarManagedFavorites)
          ++ [
            "/"
            ".Trash"
          ]
        )
    )}
    "$MYSIDES_BIN" remove "$(id -un)" >/dev/null 2>&1 || true
  '';

  # Clear all current sidebar favorites so managed order can be rebuilt.
  # `mysides list` output is captured with `|| true` so a segfault in the
  # mysides binary (e.g. from corrupted bookmarks) terminates only the
  # subshell, not the activation script.
  finderSidebarClearShell = ''
    _sidebar_lines="$("$MYSIDES_BIN" list 2>/dev/null || true)"
    echo "$_sidebar_lines" | while IFS= read -r _sidebar_line; do
      _sidebar_name="''${_sidebar_line%% -> *}"
      [ -n "$_sidebar_name" ] || continue
      "$MYSIDES_BIN" remove "$_sidebar_name" >/dev/null 2>&1 || true
    done
  '';

  # Strict add mode for configureFinderSidebar: preserve per-item failure logs.
  finderSidebarAddManagedStrictShell = builtins.concatStringsSep "\n" (
    map (
      favorite: "add_favorite ${lib.escapeShellArg favorite.name} ${lib.escapeShellArg favorite.url}"
    ) finderSidebarManagedFavorites
  );

  # Best-effort add mode for refreshFinderServices: preserve soft-fail behavior.
  finderSidebarAddManagedBestEffortShell = builtins.concatStringsSep "\n" (
    map (
      favorite:
      ''"$MYSIDES_BIN" add ${lib.escapeShellArg favorite.name} ${lib.escapeShellArg favorite.url} >/dev/null 2>&1 || true''
    ) finderSidebarManagedFavorites
  );

  # Remove Finder defaults that can reappear after daemon restarts.
  finderSidebarRemoveDefaultExtrasShell = ''
    "$MYSIDES_BIN" remove "/" >/dev/null 2>&1 || true
    "$MYSIDES_BIN" remove "$(id -un)" >/dev/null 2>&1 || true
    "$MYSIDES_BIN" remove ".Trash" >/dev/null 2>&1 || true
  '';

  # Shared strict-mode sidebar reconciliation used during activation.
  # Pre-remove known favorites first so corrupted entries are always cleared
  # even if `mysides list` segfaults on them.
  finderSidebarRebuildStrictShell = ''
    ${finderSidebarPreRemoveShell}
    ${finderSidebarClearShell}
    ${finderSidebarAddManagedStrictShell}
    ${finderSidebarRemoveDefaultExtrasShell}
  '';

  # Shared best-effort sidebar reconciliation used after Finder restarts.
  finderSidebarRebuildBestEffortShell = ''
    ${finderSidebarPreRemoveShell}
    ${finderSidebarClearShell}
    ${finderSidebarAddManagedBestEffortShell}
    ${finderSidebarRemoveDefaultExtrasShell}
  '';

  # Shared refresh for Finder sidebar/cache daemons.
  finderRefreshDaemonsShell = ''
    /usr/bin/killall sharedfilelistd 2>/dev/null || true
    /usr/bin/killall cfprefsd 2>/dev/null || true
  '';
}
