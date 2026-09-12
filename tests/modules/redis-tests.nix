# tests/modules/redis-tests.nix — Redis service registry and cross-host parity.
#
# Validates services.json Redis endpoint/type per host, launchd wiring,
# litellm readiness gate, Windows SCM service, and WinGet package declaration.
#
# Run with: nix-instantiate --eval tests/modules/redis-tests.nix

let
  lib = import <nixpkgs/lib>;
  inherit (import ../lib.nix) assert' containsRegex;

  servicesJson = builtins.fromJSON (builtins.readFile ../../src/modules/services.json);
  redis = servicesJson.redis;
  hosts = redis.hosts;

  # Network endpoint
  host = redis.network.default.host;
  port = redis.network.default.port;

  # Per-host type/service
  hostTypes = lib.mapAttrs (_: v: v.type or null) hosts;
  hostServices = lib.mapAttrs (_: v: v.service or null) hosts;

  # Source files for cross-platform wiring assertions
  aiNix = builtins.readFile ../../src/hosts/MacBook/ai.nix;
  redisNix = builtins.readFile ../../src/modules/redis.nix;
  daemonSh = builtins.readFile ../../src/scripts/services/litellm-daemon.sh;
  syncRedisPs1 = builtins.readFile ../../src/platforms/Windows/modules/system/Sync-RedisService.ps1;
  applyPs1 = builtins.readFile ../../src/hosts/Windows/apply.ps1;
  packagesDsc = builtins.readFile ../../src/hosts/Windows/system/packages.dsc.yml;
  lockfile = builtins.fromJSON (builtins.readFile ../../src/lockfiles/lockfile.json);
in
{
  tests = builtins.filter (x: x != null) [
    # --- Behavioral: services.json structure ---
    (assert' (host == "127.0.0.1") "redis must bind loopback, got ${host}")
    (assert' (port == 6379) "redis must use port 6379, got ${toString port}")
    (assert' (
      hostTypes.MacBook == "launchctl" && hostServices.MacBook == "local.redis"
    ) "MacBook redis must be local.redis launchctl")
    (assert' (
      hostTypes.NixOS == "systemctl" && hostServices.NixOS == "nucleus-redis.service"
    ) "NixOS redis must be nucleus-redis.service systemctl")
    (assert' (
      hostTypes.Windows == "native" && hostServices.Windows == "nucleus-redis"
    ) "Windows redis must be nucleus-redis native")
    (assert' (
      !lib.any (t: t == "omitted") (lib.attrValues hostTypes)
    ) "no redis host may be omitted")

    # --- MacBook: launchd.daemons."redis" present ---
    (assert' (containsRegex "launchd.daemons.\"redis\"" redisNix) "macbook: launchd.daemons.redis present")
    (assert' (containsRegex "Label = \"local.redis\";" redisNix) "macbook: Label = local.redis")

    # --- MacBook: binds loopback + requires SOPS password ---
    (assert' (containsRegex ("--bind " + "$" + "{redisCfg.host}") redisNix) "macbook: binds loopback host")
    (assert' (containsRegex ("--port " + "$" + "{toString redisCfg.port}") redisNix) "macbook: binds loopback port")
    (assert' (containsRegex "--requirepass \\\\\\\"$(cat " redisNix) "macbook: requires password from SOPS")
    (assert' (containsRegex "env_redis_password.path})\\\\\"" redisNix) "macbook: env_redis_password path")
    (assert' (containsRegex "UserName = username;" redisNix) "macbook: runs as user")

    # --- MacBook: litellm readiness gate env vars ---
    (assert' (containsRegex "LITELLM_REDIS_POLL_TICKS = \"60\";" aiNix) "macbook: LITELLM_REDIS_POLL_TICKS set")
    (assert' (containsRegex "LITELLM_REDIS_HOST = redisCfg.host;" aiNix) "macbook: LITELLM_REDIS_HOST set")
    (assert' (containsRegex "LITELLM_REDIS_PORT = toString redisCfg.port;" aiNix) "macbook: LITELLM_REDIS_PORT set")

    # --- MacBook: litellm-daemon.sh readiness gate ---
    (assert' (containsRegex "_redis_ticks=\"" daemonSh) "daemon.sh: _redis_ticks var")
    (assert' (containsRegex "LITELLM_REDIS_POLL_TICKS:-0}\"" daemonSh) "daemon.sh: poll ticks fallback")
    (assert' (containsRegex "/dev/tcp/" daemonSh) "daemon.sh: /dev/tcp probe")
    (assert' (containsRegex "_redis_host}" daemonSh) "daemon.sh: redis host var")
    (assert' (containsRegex "_redis_port}" daemonSh) "daemon.sh: redis port var")

    # --- MacBook: services.json entry ---
    (assert' (servicesJson.redis.hosts.MacBook.type == "launchctl") "services.json: MacBook type = launchctl")
    (assert' (servicesJson.redis.hosts.MacBook.service == "local.redis") "services.json: MacBook service = local.redis")

    # --- Windows: Sync-RedisService ---
    (assert' (containsRegex "function Sync-RedisService" syncRedisPs1) "windows: Sync-RedisService function")
    (assert' (containsRegex "Set-NucleusService -Name $serviceName" syncRedisPs1) "windows: Set-NucleusService call")
    (assert' (containsRegex "bind $redisHost" syncRedisPs1) "windows: binds loopback")
    (assert' (containsRegex "requirepass $requirePass" syncRedisPs1) "windows: requires password")
    (assert' (containsRegex "env_redis_password" syncRedisPs1) "windows: env_redis_password")

    # --- Windows: apply.ps1 wiring ---
    (assert' (containsRegex "Sync-RedisService.ps1" applyPs1) "windows: apply.ps1 sources module")
    (assert' (containsRegex "Sync-RedisService -RepoRoot $repoRoot -Enabled:`$true" applyPs1) "windows: apply.ps1 calls Sync-RedisService")

    # --- Windows: WinGet package ---
    (assert' (containsRegex "id: Redis.Redis" packagesDsc) "windows: Redis.Redis in DSC")
    (assert' (lockfile.winget ? "Redis.Redis") "windows: Redis.Redis in lockfile")

    # --- Windows: services.json entry ---
    (assert' (servicesJson.redis.hosts.Windows.type == "native") "services.json: Windows type = native")
    (assert' (servicesJson.redis.hosts.Windows.service == "nucleus-redis") "services.json: Windows service = nucleus-redis")
  ];

  success = true;
  message = "Redis tests passed";
}
