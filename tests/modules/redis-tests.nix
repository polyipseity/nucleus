# tests/modules/redis-tests.nix — Redis service registry and cross-host parity.
#
# Validates services.json Redis endpoint/type per host and lockfile pin.
#
# Run with: nix-instantiate --eval tests/modules/redis-tests.nix

let
  inherit (import ../lib.nix) assert' any;

  servicesJson = builtins.fromJSON (builtins.readFile ../../src/modules/services.json);
  redis = servicesJson.redis;
  hosts = redis.hosts;

  # Network endpoint
  host = redis.network.default.host;
  port = redis.network.default.port;

  # Per-host type/service
  hostTypes = builtins.mapAttrs (_: v: v.type or null) hosts;
  hostServices = builtins.mapAttrs (_: v: v.service or null) hosts;

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
    (assert' (!any (t: t == "omitted") (builtins.attrValues hostTypes)) "no redis host may be omitted")

    # --- Lockfile ---
    (assert' (lockfile.winget ? "Redis.Redis") "windows: Redis.Redis in lockfile")
  ];

  success = true;
  message = "Redis tests passed";
}
