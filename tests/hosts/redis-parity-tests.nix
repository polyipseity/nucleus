# Static assertions for the local Redis service across all hosts.
#
# Regression guard: Every host must run a local loopback Redis instance
# so LiteLLM has a Redis backend. Previously hosts pointed REDIS_HOST at
# 127.0.0.1 with no Redis server, so litellm failed with "Connection refused".
#
# MacBook: launchd.daemons."redis", label local.redis
# Windows: native SCM service nucleus-redis
# All hosts: bind loopback, require SOPS env_redis_password

let
  lib = import <nixpkgs/lib>;

  # --- Shared source files ---
  servicesJson = builtins.fromJSON (builtins.readFile ../../../src/modules/services.json);
  redisHost = servicesJson.redis.network.default.host;
  redisPort = servicesJson.redis.network.default.port;

  # --- MacBook source files ---
  aiNix = builtins.readFile ../../../src/hosts/MacBook/ai.nix;
  redisNix = builtins.readFile ../../../src/modules/redis.nix;
  daemonSh = builtins.readFile ../../../src/scripts/services/litellm-daemon.sh;

  # --- Windows source files ---
  syncRedisPs1 = builtins.readFile ../../../src/platforms/Windows/modules/system/Sync-RedisService.ps1;
  applyPs1 = builtins.readFile ../../../src/hosts/Windows/apply.ps1;
  packagesDsc = builtins.readFile ../../../src/hosts/Windows/system/packages.dsc.yml;
  lockfile = builtins.fromJSON (builtins.readFile ../../../src/lockfiles/lockfile.json);
in

# === loopback endpoint matches services.json (shared) ===

assert redisHost == "127.0.0.1";
assert redisPort == 6379;

# === MacBook: launchd.daemons."redis" present ===

assert lib.hasInfix "launchd.daemons.\"redis\"" redisNix;
assert lib.hasInfix "Label = \"local.redis\";" redisNix;

# === MacBook: binds loopback + requires SOPS password ===

assert lib.hasInfix ("--bind " + "$" + "{redisCfg.host}") redisNix;
assert lib.hasInfix ("--port " + "$" + "{toString redisCfg.port}") redisNix;
assert lib.hasInfix "--requirepass \\\"$(cat " redisNix;
assert lib.hasInfix "env_redis_password.path})\\\"" redisNix;
assert lib.hasInfix "UserName = username;" redisNix;

# === MacBook: litellm readiness gate env vars ===

assert lib.hasInfix "LITELLM_REDIS_POLL_TICKS = \"60\";" aiNix;
assert lib.hasInfix "LITELLM_REDIS_HOST = redisCfg.host;" aiNix;
assert lib.hasInfix "LITELLM_REDIS_PORT = toString redisCfg.port;" aiNix;

# === MacBook: litellm-daemon.sh readiness gate ===

assert lib.hasInfix "_redis_ticks=\"" daemonSh;
assert lib.hasInfix "LITELLM_REDIS_POLL_TICKS:-0}\"" daemonSh;
assert lib.hasInfix "/dev/tcp/" daemonSh;
assert lib.hasInfix "_redis_host}" daemonSh;
assert lib.hasInfix "_redis_port}" daemonSh;

# === MacBook: services.json entry ===

assert servicesJson.redis.hosts.MacBook.type == "launchctl";
assert servicesJson.redis.hosts.MacBook.service == "local.redis";

# === Windows: Sync-RedisService provisions a native SCM service ===

assert lib.hasInfix "function Sync-RedisService" syncRedisPs1;
assert lib.hasInfix "Set-NucleusService -Name $serviceName" syncRedisPs1;
assert lib.hasInfix "bind $redisHost" syncRedisPs1;
assert lib.hasInfix "requirepass $requirePass" syncRedisPs1;
assert lib.hasInfix "env_redis_password" syncRedisPs1;

# === Windows: apply.ps1 wires the module + call ===

assert lib.hasInfix "Sync-RedisService.ps1" applyPs1;
assert lib.hasInfix "Sync-RedisService -RepoRoot $repoRoot -Enabled:`$true" applyPs1;

# === Windows: WinGet package declared in DSC + lockfile ===

assert lib.hasInfix "id: Redis.Redis" packagesDsc;
assert lockfile.winget ? "Redis.Redis";

# === Windows: services.json entry ===

assert servicesJson.redis.hosts.Windows.type == "native";
assert servicesJson.redis.hosts.Windows.service == "nucleus-redis";

{
  success = true;
  message = "Redis cross-host parity tests passed";
}
