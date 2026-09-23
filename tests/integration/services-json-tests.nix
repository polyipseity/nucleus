# tests/integration/services-json-tests.nix — Structural invariant tests for service management.
#
# Validates services.json data integrity: schema reference, required services,
# host validity, scope correctness, per-user justification, watchdog wiring,
# and per-service invariants (hermes-agent, redis, logging dirs).
#
# Run with: nix-instantiate --eval --strict tests/integration/services-json-tests.nix

let
  inherit (import ../lib.nix)
    assert'
    all
    any
    ;

  servicesJsonText = builtins.readFile ../../src/modules/services.json;
  parsedServices = builtins.fromJSON servicesJsonText;
  serviceNames = builtins.filter (n: parsedServices.${n} ? hosts) (builtins.attrNames parsedServices);

  knownHosts = [
    "MacBook"
    "NixOS"
    "Windows"
  ];

  requiredServices = [
    "ollama"
    "litellm"
    "jellyfin"
    "discord-music-rpc"
    "sshd"
    "ssh-agent"
    "cloud-drive"
    "rdp"
    "linux-builder"
    "service-watchdog"
  ];

  userScopedServices = [
    "discord-music-rpc"
    "ssh-agent"
    "cloud-drive"
  ];

  macbookSystemServices = [
    "ollama"
    "litellm"
  ];

  # --- Hermes Agent (from hermes-agent-tests.nix) ---
  hermes = parsedServices.hermes-agent;
  hermesHosts = hermes.hosts;
  hermesHostTypes = builtins.mapAttrs (_: v: v.type or null) hermesHosts;
  hermesHostServices = builtins.mapAttrs (_: v: v.service or null) hermesHosts;

  # --- Redis (from redis-tests.nix) ---
  redis = parsedServices.redis;
  redisHosts = redis.hosts;
  redisHostTypes = builtins.mapAttrs (_: v: v.type or null) redisHosts;
  redisHostServices = builtins.mapAttrs (_: v: v.service or null) redisHosts;
  lockfile = builtins.fromJSON (builtins.readFile ../../src/lockfiles/lockfile.json);

  # --- Logging dirs (from logging-dirs-tests.nix) ---
  camillaDirs = parsedServices.camilladsp.logging.dirs;
  camillaGuiDirs = parsedServices.camillagui-backend.logging.dirs;
  caddyDirs = parsedServices.caddy.logging.dirs;
  jellyfinDirs = parsedServices.jellyfin.logging.dirs;
  linuxBuilderDirs = parsedServices.linux-builder.logging.dirs;
  litellmDirs = parsedServices.litellm.logging.dirs;
  ollamaDirs = parsedServices.ollama.logging.dirs;
  watchdogDirs = parsedServices.service-watchdog.logging.dirs;
  redisDirs = parsedServices.redis.logging.dirs;
  camillaHeartbeatDirs = parsedServices."camilladsp-heartbeat".logging.dirs;
  camillaRunAsUser = parsedServices.camilladsp.hosts.MacBook.runAsUser;
  camillaGuiRunAsUser = parsedServices.camillagui-backend.hosts.MacBook.runAsUser;
  caddyRunAsUser = parsedServices.caddy.hosts.MacBook.runAsUser;
  jellyfinRunAsUser = parsedServices.jellyfin.hosts.MacBook.runAsUser;
  litellmRunAsUser = parsedServices.litellm.hosts.MacBook.runAsUser;
  camillaHeartbeatScope = parsedServices."camilladsp-heartbeat".hosts.MacBook.scope;
  camillaRunScope = parsedServices.camilladsp.hosts.MacBook.scope;

  allTests = [
    # --- Structural invariants ---
    (assert' (all (
      name: parsedServices.${name} ? displayName
    ) serviceNames) "Every service must have a displayName field")

    (assert' (all (
      name: builtins.hasAttr name parsedServices
    ) requiredServices) "All required services must be present in services.json")

    (assert' (all (
      name:
      let
        entry = parsedServices.${name};
        hosts = builtins.attrNames entry.hosts;
      in
      any (h: entry.hosts.${h}.type != "omitted") hosts
    ) serviceNames) "Every service must have at least one non-omitted host")

    (assert' (all (
      name:
      let
        entry = parsedServices.${name};
      in
      all (h: any (kh: kh == h) knownHosts) (builtins.attrNames entry.hosts)
    ) serviceNames) "All host keys must be MacBook, NixOS, or Windows")

    (assert' (all (
      name: parsedServices.${name}.hosts.MacBook.scope == "system"
    ) macbookSystemServices) "ollama and litellm must be system-scoped on MacBook")

    (assert' (all (
      name:
      let
        entry = parsedServices.${name};
        hosts = builtins.attrNames entry.hosts;
      in
      all (h: entry.hosts.${h} ? justification) hosts
    ) userScopedServices) "User-scoped services must have justification on every host")

    (assert' (parsedServices ? service-watchdog) "service-watchdog present in services.json")
    (assert' (parsedServices.service-watchdog ? hosts) "service-watchdog has hosts")
    (assert' (parsedServices.service-watchdog ? displayName) "service-watchdog has displayName")

    # --- Hermes Agent invariants ---
    (assert' (hermes ? displayName) "hermes-agent must have displayName")
    (assert' (hermes.displayName == "Hermes Agent") "hermes-agent displayName must be 'Hermes Agent'")
    (assert' (hermes ? logging) "hermes-agent must have logging config")
    (assert' (hermes.logging.capture == "all") "hermes-agent must capture all logs")
    (assert' (hermesHostTypes.MacBook == "macos-launchctl") "MacBook hermes-agent must be launchctl")
    (assert' (
      hermesHostServices.MacBook == "org.nix-community.home.hermes-agent"
    ) "MacBook hermes-agent service must be org.nix-community.home.hermes-agent")
    (assert' (hermesHosts.MacBook.scope == "user") "MacBook hermes-agent must be user-scoped")
    (assert' (hermesHosts.MacBook.launchdDomain == "gui") "MacBook hermes-agent must use gui domain")
    (assert' (hermesHostTypes.NixOS == "nixos-systemctl") "NixOS hermes-agent must be systemctl")
    (assert' (
      hermesHostServices.NixOS == "hermes-agent.service"
    ) "NixOS hermes-agent service must be hermes-agent.service")
    (assert' (hermesHosts.NixOS.scope == "user") "NixOS hermes-agent must be user-scoped")
    (assert' (hermesHostTypes.Windows == "windows-native") "Windows hermes-agent must be native SCM")
    (assert' (
      hermesHostServices.Windows == "hermes-gateway"
    ) "Windows hermes-agent service must be hermes-gateway")

    # --- Redis invariants ---
    (assert' (redis.network.default.host == "127.0.0.1") "redis must bind loopback")
    (assert' (redis.network.default.port == 6379) "redis must use port 6379")
    (assert' (
      redisHostTypes.MacBook == "macos-launchctl" && redisHostServices.MacBook == "local.redis"
    ) "MacBook redis must be local.redis launchctl")
    (assert' (
      redisHostTypes.NixOS == "nixos-systemctl" && redisHostServices.NixOS == "nucleus-redis.service"
    ) "NixOS redis must be nucleus-redis.service systemctl")
    (assert' (
      redisHostTypes.Windows == "windows-native" && redisHostServices.Windows == "nucleus-redis"
    ) "Windows redis must be nucleus-redis native")
    (assert' (
      !any (t: t == "omitted") (builtins.attrValues redisHostTypes)
    ) "no redis host may be omitted")
    (assert' (lockfile.winget ? "Redis.Redis") "windows: Redis.Redis in lockfile")

    # --- Logging dirs ---
    (assert' (
      camillaDirs.system == [ "camilladsp" ] && camillaDirs.user == [ "camilladsp" ]
    ) "camilladsp: dirs correct")
    (assert' (
      camillaGuiDirs.system == [ "camillagui-backend" ] && camillaGuiDirs.user == [ "camillagui-backend" ]
    ) "camillagui-backend: dirs correct")
    (assert' (caddyDirs.system == [ "caddy" ] && caddyDirs.user == [ ]) "caddy: dirs correct")
    (assert' (
      jellyfinDirs.system == [
        "jellyfin"
        "jellyfin-app"
      ]
      && jellyfinDirs.user == [ ]
    ) "jellyfin: dirs correct")
    (assert' (linuxBuilderDirs.system == [ "linux-builder" ]) "linux-builder: dirs correct")
    (assert' (litellmDirs.system == [ "litellm" ]) "litellm: dirs correct")
    (assert' (ollamaDirs.system == [ "ollama" ]) "ollama: dirs correct")
    (assert' (watchdogDirs.system == [ "service-watchdog" ]) "service-watchdog: dirs correct")
    (assert' (redisDirs.system == [ "redis" ] && redisDirs.user == [ ]) "redis: dirs correct")
    (assert' (
      camillaHeartbeatDirs.system == [ ] && camillaHeartbeatDirs.user == [ "camilladsp-heartbeat" ]
    ) "camilladsp-heartbeat: dirs correct")
    (assert' camillaRunAsUser "camilladsp: runAsUser=true")
    (assert' camillaGuiRunAsUser "camillagui-backend: runAsUser=true")
    (assert' caddyRunAsUser "caddy: runAsUser=true")
    (assert' jellyfinRunAsUser "jellyfin: runAsUser=true")
    (assert' litellmRunAsUser "litellm: runAsUser=true")
    (assert' (camillaHeartbeatScope == "user") "camilladsp-heartbeat: scope=user")
    (assert' (camillaRunScope == "system") "camilladsp: scope=system")
  ];
in
builtins.seq (builtins.deepSeq allTests null) {
  success = true;
  testCount = builtins.length allTests;
  message = "All ${builtins.toString (builtins.length allTests)} services.json structural tests passed";
}
