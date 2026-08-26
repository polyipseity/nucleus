# platforms/macOS/modules/finder-sidebar.nix — Finder sidebar favorites automation.
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
  inherit finderSidebarManagedFavorites;

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

}
