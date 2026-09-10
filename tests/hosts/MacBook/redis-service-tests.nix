# Static assertions for the local Redis service on MacBook.
#
# Regression guard: MacBook must run a local loopback Redis instance
# (launchd.daemons."redis", label local.redis) so LiteLLM has a Redis backend
# on macOS — previously MacBook pointed REDIS_HOST at 127.0.0.1 with no Redis
# server, so litellm failed with "Connection refused". The daemon must bind
# loopback, require the SOPS env_redis_password, and the litellm daemon must
# pass the opt-in readiness-gate env vars.

let
  lib = import <nixpkgs/lib>;

  aiNix = builtins.readFile ../../../src/hosts/MacBook/ai.nix;
  redisNix = builtins.readFile ../../../src/modules/redis.nix;
  daemonSh = builtins.readFile ../../../src/scripts/services/litellm-daemon.sh;
  servicesJson = builtins.fromJSON (builtins.readFile ../../../src/modules/services.json);
  redisHost = servicesJson.redis.network.default.host;
  redisPort = servicesJson.redis.network.default.port;

  # The redis launchd daemon is owned by the shared redis.nix module.
  redisBlock = redisNix;
in

# === launchd.daemons."redis" present ===

assert lib.hasInfix "launchd.daemons.\"redis\"" redisNix;
assert lib.hasInfix "Label = \"local.redis\";" redisBlock;

# === binds loopback + requires SOPS password ===
# Source uses literal ${redisCfg.host}/${redisCfg.port}; build the search
# string from parts to avoid Nix interpolation of ${...}.

assert lib.hasInfix ("--bind " + "$" + "{redisCfg.host}") redisBlock;
assert lib.hasInfix ("--port " + "$" + "{toString redisCfg.port}") redisBlock;
assert lib.hasInfix "--requirepass \\\"$(cat " redisBlock;
assert lib.hasInfix "env_redis_password.path})\\\"" redisBlock;
assert lib.hasInfix "UserName = username;" redisBlock;

# === loopback endpoint matches services.json ===

assert redisHost == "127.0.0.1";
assert redisPort == 6379;

# === litellm readiness gate env vars ===

assert lib.hasInfix "LITELLM_REDIS_POLL_TICKS = \"60\";" aiNix;
assert lib.hasInfix "LITELLM_REDIS_HOST = redisCfg.host;" aiNix;
assert lib.hasInfix "LITELLM_REDIS_PORT = toString redisCfg.port;" aiNix;

# === litellm-daemon.sh readiness gate ===

assert lib.hasInfix "_redis_ticks=\"" daemonSh;
assert lib.hasInfix "LITELLM_REDIS_POLL_TICKS:-0}\"" daemonSh;
assert lib.hasInfix "/dev/tcp/" daemonSh;
assert lib.hasInfix "_redis_host}" daemonSh;
assert lib.hasInfix "_redis_port}" daemonSh;

# === services.json MacBook redis entry ===

assert servicesJson.redis.hosts.MacBook.type == "launchctl";
assert servicesJson.redis.hosts.MacBook.service == "local.redis";

{
  success = true;
  message = "MacBook local Redis service tests passed";
}
