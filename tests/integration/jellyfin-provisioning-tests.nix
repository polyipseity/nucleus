# tests/integration/jellyfin-provisioning-tests.nix — Validate Jellyfin provisioning parity.

let
  inherit (import ../lib.nix) assert' containsRegex;
  hasAdminAccount =
    accounts:
    builtins.any (
      account: (account.id or "") == "polyipseity" && ((account.isAdmin or false) == true)
    ) accounts;

  coreText = builtins.readFile ../../src/modules/core.nix;
  applyScriptText = builtins.readFile ../../src/scripts/apply.sh;
  macbookDefaultText = builtins.readFile ../../src/hosts/MacBook/default.nix;
  macbookJellyfinText = builtins.readFile ../../src/hosts/MacBook/jellyfin.nix;
  macbookManualText = builtins.readFile ../../src/hosts/MacBook/MANUAL.md;
  nixosDefaultText = builtins.readFile ../../src/hosts/NixOS/default.nix;
  nixosJellyfinText = builtins.readFile ../../src/hosts/NixOS/jellyfin.nix;
  nixosManualText = builtins.readFile ../../src/hosts/NixOS/MANUAL.md;
  linuxText = builtins.readFile ../../src/modules/linux.nix;
  macosText = builtins.readFile ../../src/modules/macos.nix;
  usersRegistry = builtins.fromJSON (builtins.readFile ../../src/modules/users.json);
  windowsApplyText = builtins.readFile ../../src/hosts/Windows/apply.ps1;
  windowsCaddyTrustText = builtins.readFile ../../src/hosts/Windows/modules/system/Sync-CaddyLocalCA.ps1;
  caddyTrustScriptText = builtins.readFile ../../src/scripts/services/caddy-trust.sh;
  windowsCaddyServiceText = builtins.readFile ../../src/hosts/Windows/modules/system/Sync-CaddyService.ps1;
  windowsJellyfinAccountText = builtins.readFile ../../src/hosts/Windows/modules/system/Sync-JellyfinAccount.ps1;
  windowsJellyfinLibraryText = builtins.readFile ../../src/hosts/Windows/modules/system/Sync-JellyfinLibrary.ps1;
  windowsManualText = builtins.readFile ../../src/hosts/Windows/MANUAL.md;
  windowsUsersRegistry = builtins.fromJSON (builtins.readFile ../../src/hosts/Windows/users.json);
  windowsSystemPackagesText = builtins.readFile ../../src/hosts/Windows/system/packages.dsc.yml;
  jellyfinSyncScript = builtins.readFile ../../src/scripts/services/jellyfin-sync.sh;

  test_core_installs_jellyfin = assert' (containsRegex ''pkgs\.jellyfin'' coreText) "core.nix must install pkgs.jellyfin on Nix-managed hosts";

  test_nixos_imports_host_jellyfin_module = assert' (containsRegex ''\./jellyfin\.nix'' nixosDefaultText) "NixOS host entrypoint must import ./jellyfin.nix";

  test_nixos_imports_https_proxy_modules = assert' (
    containsRegex ''\./https-proxy\.nix'' nixosDefaultText
    && containsRegex ''\.\./\.\./modules/https-proxy\.nix'' nixosDefaultText
  ) "NixOS host entrypoint must import https-proxy mapping modules";

  test_nixos_runs_shared_jellyfin_service = assert' (
    containsRegex ''services\.jellyfin'' nixosJellyfinText
    && containsRegex "enable = true" nixosJellyfinText
  ) "NixOS must provision Jellyfin as a host-level shared service";

  test_macbook_imports_host_jellyfin_module = assert' (containsRegex ''\./jellyfin\.nix'' macbookDefaultText) "MacBook host entrypoint must import ./jellyfin.nix";

  test_macbook_runs_shared_jellyfin_daemon = assert' (
    containsRegex ''launchd\.daemons\.jellyfin'' macbookJellyfinText
    && containsRegex ''state_root="/Users/Shared/Jellyfin"'' macbookJellyfinText
  ) "macOS must provision Jellyfin as a host-level shared launchd daemon";

  test_macbook_declares_https_proxy_virtual_host = assert' (
    containsRegex ''nucleus\.httpsProxy\.virtualHosts\.jellyfin'' macbookJellyfinText
    && containsRegex "listenPort = 8920" macbookJellyfinText
    && containsRegex "upstreamPort = jellyfinHttpPort" macbookJellyfinText
  ) "macOS must declare Jellyfin HTTPS proxy virtual host via nucleus.httpsProxy";

  test_nixos_declares_https_proxy_virtual_host = assert' (
    containsRegex ''nucleus\.httpsProxy\.virtualHosts\.jellyfin'' nixosJellyfinText
    && containsRegex "listenPort = 8920" nixosJellyfinText
    && containsRegex "upstreamPort = jellyfinHttpPort" nixosJellyfinText
  ) "NixOS must declare Jellyfin HTTPS proxy virtual host via nucleus.httpsProxy";

  test_no_per_user_jellyfin_units = assert' (
    !containsRegex "jellyfin-media-server" linuxText && !containsRegex "jellyfin-media-server" macosText
  ) "Per-user Jellyfin units must not exist in shared linux.nix or macos.nix modules";

  test_windows_installs_jellyfin_server = assert' (containsRegex ''id: Jellyfin\.Server'' windowsSystemPackagesText) "Windows DSC must install Jellyfin.Server via WinGet";

  test_windows_installs_caddy_for_https_proxy = assert' (containsRegex ''id: CaddyServer\.Caddy'' windowsSystemPackagesText) "Windows DSC must install Caddy for Jellyfin HTTPS proxy";

  test_windows_wires_https_proxy_module = assert' (
    containsRegex "Sync-CaddyService" windowsApplyText
    && containsRegex "function Sync-CaddyService" windowsCaddyServiceText
    && containsRegex "auto_https disable_redirects" windowsCaddyServiceText
    && containsRegex "tls internal" windowsCaddyServiceText
  ) "Windows apply flow must converge Caddy HTTPS proxy service";

  test_host_manuals_document_jellyfin_endpoints = assert' (
    containsRegex "https://localhost:8920" macbookManualText
    && containsRegex ''http://127\.0\.0\.1:8096'' macbookManualText
    && containsRegex "https://localhost:8920" nixosManualText
    && containsRegex ''http://127\.0\.0\.1:8096'' nixosManualText
    && containsRegex "https://localhost:8920" windowsManualText
    && containsRegex ''http://127\.0\.0\.1:8096'' windowsManualText
  ) "Host manuals must document Jellyfin HTTPS and loopback HTTP endpoints";

  test_polyipseity_declared_as_jellyfin_admin = assert' (
    hasAdminAccount (usersRegistry.polyipseity.jellyfin.accounts or [ ])
    && hasAdminAccount (windowsUsersRegistry.users.polyipseity.jellyfin.accounts or [ ])
  ) "polyipseity Jellyfin account must be declared as admin on POSIX and Windows user registries";

  test_jellyfin_admin_flag_defaults_false_in_sync_logic = assert' (
    containsRegex ''isAdmin: \(\.isAdmin // false\)'' jellyfinSyncScript
    && containsRegex ''isAdmin = if \(\$null -eq \$account\.isAdmin\) \{ \$false \}'' windowsJellyfinAccountText
  ) "Jellyfin account sync logic must default isAdmin to false when omitted";

  test_jellyfin_admin_policy_is_converged = assert' (
    containsRegex ''/Users/\$\{_jfsa_user_id\}/Policy'' jellyfinSyncScript
    && containsRegex ''/Users/\$\(\$matchingUser\.Id\)/Policy'' windowsJellyfinAccountText
  ) "Jellyfin account sync must converge admin policy on POSIX and Windows";

  test_caddy_local_ca_trust_is_automated = assert' (
    containsRegex "run_caddy_local_ca_trust" applyScriptText
    && containsRegex ''caddy-trust\.sh'' applyScriptText
    && containsRegex ''caddy trust --address 127\.0\.0\.1:2019'' caddyTrustScriptText
    && containsRegex "Sync-CaddyLocalCA" windowsApplyText
    && containsRegex "function Sync-CaddyLocalCA" windowsCaddyTrustText
    && containsRegex ''caddy.*trust --address 127\.0\.0\.1:2019'' windowsCaddyTrustText
  ) "Caddy local CA trust must be automated across POSIX and Windows apply flows";

  test_posix_library_sync_function_exists = assert' (
    containsRegex "_jfs_sync_libraries" jellyfinSyncScript
    && containsRegex "Library/VirtualFolders" jellyfinSyncScript
    && containsRegex "LibraryOptions" jellyfinSyncScript
  ) "jellyfin-sync.sh must contain the _jfs_sync_libraries function with Jellyfin API calls";

  test_posix_library_sync_wired_in_all_branches = assert' (containsRegex "jellyfin-sync\.sh" applyScriptText) "POSIX library sync dispatch must appear in apply.sh for Darwin, NixOS, and Linux branches";

  test_posix_library_sync_passes_repo_root = assert' (containsRegex "NUCLEUS_REPO_ROOT=.*sh.*jellyfin-sync\\.sh" applyScriptText) "apply.sh must pass NUCLEUS_REPO_ROOT environment variable to jellyfin-sync.sh";

  test_posix_polyipseity_library_declared_in_users_json = assert' (
    let
      libs = usersRegistry.polyipseity.jellyfin.libraries or [ ];
      names = builtins.map (lib: lib.name or "") libs;
    in
    (builtins.length libs) >= 2
    && builtins.any (n: n == "music videos") names
    && builtins.any (n: n == "playlists") names
  ) "polyipseity must declare jellyfin libraries for music videos and playlists in POSIX users.json";

  test_windows_polyipseity_library_declared_in_users_json =
    assert'
      (
        let
          libs = windowsUsersRegistry.users.polyipseity.jellyfin.libraries or [ ];
          names = builtins.map (lib: lib.name or "") libs;
        in
        (builtins.length libs) >= 2
        && builtins.any (n: n == "music videos") names
        && builtins.any (n: n == "playlists") names
      )
      "polyipseity must declare jellyfin libraries for music videos and playlists in Windows users.json";

  test_windows_library_module_wired = assert' (
    containsRegex "Sync-JellyfinLibrary" windowsApplyText
    && containsRegex "function Sync-JellyfinLibrary" windowsJellyfinLibraryText
    && containsRegex "Library/VirtualFolders" windowsJellyfinLibraryText
  ) "Windows apply flow must import and call Sync-JellyfinLibrary module";

  allTests = [
    test_core_installs_jellyfin
    test_nixos_imports_host_jellyfin_module
    test_nixos_runs_shared_jellyfin_service
    test_macbook_imports_host_jellyfin_module
    test_macbook_runs_shared_jellyfin_daemon
    test_nixos_imports_https_proxy_modules
    test_macbook_declares_https_proxy_virtual_host
    test_nixos_declares_https_proxy_virtual_host
    test_no_per_user_jellyfin_units
    test_windows_installs_jellyfin_server
    test_windows_installs_caddy_for_https_proxy
    test_windows_wires_https_proxy_module
    test_host_manuals_document_jellyfin_endpoints
    test_polyipseity_declared_as_jellyfin_admin
    test_jellyfin_admin_flag_defaults_false_in_sync_logic
    test_jellyfin_admin_policy_is_converged
    test_caddy_local_ca_trust_is_automated
    test_posix_library_sync_function_exists
    test_posix_library_sync_wired_in_all_branches
    test_posix_library_sync_passes_repo_root
    test_posix_polyipseity_library_declared_in_users_json
    test_windows_polyipseity_library_declared_in_users_json
    test_windows_library_module_wired
  ];
in
builtins.seq (builtins.deepSeq allTests) {
  success = true;
  testCount = builtins.length allTests;
  message = "All ${toString (builtins.length allTests)} Jellyfin provisioning tests passed";
}
