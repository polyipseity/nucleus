# platforms/macOS/modules/finder-sidebar.nix - deterministic Finder sidebar state
# via mysides, used by macos.nix activation hooks.
{ config, lib, ... }:
let
  # mysides needs encoded file:// URIs; raw spaces fail silently. lib.escapeURL
  # (RFC 3986) encodes, then : and / are decoded back so the URI stays valid.
  # Source: https://en.wikipedia.org/wiki/Percent-encoding
  uriEncode = url: builtins.replaceStrings [ "%3A" "%2F" ] [ ":" "/" ] (lib.escapeURL url);

  # Managed Finder favorites, in order.
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

  # Managed favorite count, used to scope the sidebar-order comparison.
  finderSidebarManagedCount = builtins.length finderSidebarManagedFavorites;

  # Expected order, derived from the managed favorites list.
  finderSidebarExpectedOrder = builtins.concatStringsSep "|" (
    map (favorite: favorite.name) finderSidebarManagedFavorites
  );

  # macOS guarantees these under $HOME, so the symlink guard is skipped.
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
