# tests/modules/redis-service-tests.nix — Redis service registry invariants.
#
# Every host must run a local loopback Redis instance (no cross-host tailnet
# dependency). REDIS_HOST/REDIS_PORT resolve to 127.0.0.1:6379 on all hosts,
# and services.json must declare a real service runtime for each host (not
# "omitted"). NixOS keeps its systemctl nucleus-redis.service.

let
  lib = import <nixpkgs/lib>;
  inherit (import ../lib.nix) assert';

  servicesJson = builtins.fromJSON (builtins.readFile ../../src/modules/services.json);
  redis = servicesJson.redis;
  hosts = redis.hosts;

  # REDIS_HOST/REDIS_PORT come from the env catalog default (verified by
  # env-catalog-tests.nix); here we assert the network endpoint is loopback.
  host = redis.network.default.host;
  port = redis.network.default.port;

  # Every host must declare a real service runtime (not omitted).
  hostTypes = lib.mapAttrs (_: v: v.type or null) hosts;
  hostServices = lib.mapAttrs (_: v: v.service or null) hosts;
in
{
  test_redis_loopback = assert' (host == "127.0.0.1") "redis must bind loopback, got ${host}";
  test_redis_port = assert' (port == 6379) "redis must use port 6379, got ${toString port}";

  test_macbook_launchctl = assert' (
    hostTypes.MacBook == "launchctl" && hostServices.MacBook == "local.redis"
  ) "MacBook redis must be local.redis launchctl, got ${hostTypes.MacBook}";
  test_nixos_systemctl = assert' (
    hostTypes.NixOS == "systemctl" && hostServices.NixOS == "nucleus-redis.service"
  ) "NixOS redis must be nucleus-redis.service systemctl, got ${hostTypes.NixOS}";
  test_windows_native = assert' (
    hostTypes.Windows == "native" && hostServices.Windows == "nucleus-redis"
  ) "Windows redis must be nucleus-redis native, got ${hostTypes.Windows}";

  test_no_omitted_hosts = assert' (
    !lib.any (t: t == "omitted") (lib.attrValues hostTypes)
  ) "no redis host may be omitted (all hosts run local Redis)";
}
