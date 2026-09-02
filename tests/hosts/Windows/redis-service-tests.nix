# Static assertions for the local Redis service on Windows.
#
# Regression guard: Windows must run a local loopback Redis instance
# (native SCM service nucleus-redis) so LiteLLM has a Redis backend on Windows
# — previously Windows pointed REDIS_HOST at 127.0.0.1 with no Redis server.
# The service must bind loopback, require the SOPS env_redis_password, and be
# wired into apply.ps1. The WinGet package must be declared in both the DSC
# packages file and lockfile.json.

let
  lib = import <nixpkgs/lib>;

  syncRedisPs1 = builtins.readFile ../../../src/platforms/Windows/modules/system/Sync-RedisService.ps1;
  applyPs1 = builtins.readFile ../../../src/hosts/Windows/apply.ps1;
  packagesDsc = builtins.readFile ../../../src/hosts/Windows/system/packages.dsc.yml;
  lockfile = builtins.fromJSON (builtins.readFile ../../../src/lockfiles/lockfile.json);
  servicesJson = builtins.fromJSON (builtins.readFile ../../../src/modules/services.json);
  redisHost = servicesJson.redis.network.default.host;
  redisPort = servicesJson.redis.network.default.port;
in

# === Sync-RedisService provisions a native SCM service ===

assert lib.hasInfix "function Sync-RedisService" syncRedisPs1;
assert lib.hasInfix "Set-NucleusService -Name $serviceName" syncRedisPs1;
assert lib.hasInfix "bind $redisHost" syncRedisPs1;
assert lib.hasInfix "requirepass $requirePass" syncRedisPs1;
assert lib.hasInfix "env_redis_password" syncRedisPs1;

# === loopback endpoint matches services.json ===

assert redisHost == "127.0.0.1";
assert redisPort == 6379;

# === apply.ps1 wires the module + call ===

assert lib.hasInfix "Sync-RedisService.ps1" applyPs1;
assert lib.hasInfix "Sync-RedisService -RepoRoot $repoRoot -Enabled:`$true" applyPs1;

# === WinGet package declared in DSC + lockfile ===

assert lib.hasInfix "id: Redis.Redis" packagesDsc;
assert lockfile.winget ? "Redis.Redis";

# === services.json Windows redis entry ===

assert servicesJson.redis.hosts.Windows.type == "native";
assert servicesJson.redis.hosts.Windows.service == "nucleus-redis";

{
  success = true;
  message = "Windows local Redis service tests passed";
}
