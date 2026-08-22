# tests/modules/logging-dirs-tests.nix — Log directory consistency in services.json and activation.nix.

let
  inherit (import ../lib.nix) assert';

  services = builtins.fromJSON (builtins.readFile ../../src/modules/services.json);

  # Verify services that must have specific dirs entries.
  camillaDirs = services.camilladsp.logging.dirs;
  camillaGuiDirs = services.camillagui-backend.logging.dirs;
  caddyDirs = services.caddy.logging.dirs;
  jellyfinDirs = services.jellyfin.logging.dirs;
  linuxBuilderDirs = services.linux-builder.logging.dirs;
  litellmDirs = services.litellm.logging.dirs;
  ollamaDirs = services.ollama.logging.dirs;
  watchdogDirs = services.service-watchdog.logging.dirs;

  # Verify runAsUser fields.
  camillaRunAsUser = services.camilladsp.hosts.MacBook.runAsUser;
  camillaGuiRunAsUser = services.camillagui-backend.hosts.MacBook.runAsUser;
  caddyRunAsUser = services.caddy.hosts.MacBook.runAsUser;
  jellyfinRunAsUser = services.jellyfin.hosts.MacBook.runAsUser;
  litellmRunAsUser = services.litellm.hosts.MacBook.runAsUser;

  # Verify launchd domain: heartbeat must be a user agent (TCC can read
  # user-home config); run service stays a system daemon.
  camillaHeartbeatDomain = services."camilladsp-heartbeat".hosts.MacBook.domain;
  camillaRunDomain = services.camilladsp.hosts.MacBook.domain;

  # --- Tests ---
  test_camilladsp_dirs = assert' (
    camillaDirs.system == [ "camilladsp" ] && camillaDirs.user == [ "camilladsp" ]
  ) "camilladsp: dirs.system=[camilladsp] dirs.user=[camilladsp]";

  test_camillagui_dirs = assert' (
    camillaGuiDirs.system == [ "camillagui-backend" ] && camillaGuiDirs.user == [ "camillagui-backend" ]
  ) "camillagui-backend: dirs.system=[camillagui-backend] dirs.user=[camillagui-backend]";

  test_caddy_dirs = assert' (
    caddyDirs.system == [ "caddy" ] && caddyDirs.user == [ ]
  ) "caddy: dirs.system=[caddy] dirs.user=[]";

  test_jellyfin_dirs = assert' (
    jellyfinDirs.system == [
      "jellyfin"
      "jellyfin-app"
    ]
    && jellyfinDirs.user == [ ]
  ) "jellyfin: dirs.system=[jellyfin,jellyfin-app] dirs.user=[]";

  test_linux_builder_dirs = assert' (
    linuxBuilderDirs.system == [ "linux-builder" ]
  ) "linux-builder: dirs.system=[linux-builder]";

  test_litellm_dirs = assert' (litellmDirs.system == [ "litellm" ]) "litellm: dirs.system=[litellm]";

  test_ollama_dirs = assert' (ollamaDirs.system == [ "ollama" ]) "ollama: dirs.system=[ollama]";

  test_watchdog_dirs = assert' (
    watchdogDirs.system == [ "service-watchdog" ]
  ) "service-watchdog: dirs.system=[service-watchdog]";

  test_camilladsp_runAsUser = assert' camillaRunAsUser "camilladsp: runAsUser=true";
  test_camillagui_runAsUser = assert' camillaGuiRunAsUser "camillagui-backend: runAsUser=true";
  test_caddy_runAsUser = assert' caddyRunAsUser "caddy: runAsUser=true";
  test_jellyfin_runAsUser = assert' jellyfinRunAsUser "jellyfin: runAsUser=true";
  test_litellm_runAsUser = assert' litellmRunAsUser "litellm: runAsUser=true";

  test_camilladsp_heartbeat_domain = assert' (
    camillaHeartbeatDomain == "user"
  ) "camilladsp-heartbeat: MacBook domain=user (TCC-readable user agent)";
  test_camilladsp_run_domain = assert' (
    camillaRunDomain == "system"
  ) "camilladsp: MacBook domain=system (no user-home config read)";

in
{
  tests = builtins.filter (x: x != null) [
    test_camilladsp_dirs
    test_camillagui_dirs
    test_caddy_dirs
    test_jellyfin_dirs
    test_linux_builder_dirs
    test_litellm_dirs
    test_ollama_dirs
    test_watchdog_dirs
    test_camilladsp_runAsUser
    test_camillagui_runAsUser
    test_caddy_runAsUser
    test_jellyfin_runAsUser
    test_litellm_runAsUser
    test_camilladsp_heartbeat_domain
    test_camilladsp_run_domain
  ];
  success = true;
  allPass = true;
}
