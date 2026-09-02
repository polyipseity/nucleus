# General-purpose loopback Redis service for all hosts.
#
# Redis is a generic in-memory data store used for cross-service coordination
# and caching (LiteLLM is one consumer, but the service itself is not AI-
# specific). This module owns the Redis server definition on macOS and NixOS;
# Windows provisions the equivalent native SCM service via
# src/platforms/Windows/modules/system/Sync-RedisService.ps1.
#
# The endpoint (host/port) comes from the centralized service registry
# (src/modules/services.json). The password comes from the SOPS
# env_redis_password secret, exposed to consumers as REDIS_PASSWORD by the
# shared env catalog (src/modules/env-catalog.nix).
{
  config,
  lib,
  pkgs,
  username,
  ...
}:
let
  # Centralized service registry — single source of truth for network config.
  servicesJSON = builtins.fromJSON (builtins.readFile ./services.json);
  redisCfg = servicesJSON.redis.network.default;
in
{
  # macOS: nix-darwin has no services.redis module, so run redis-server
  # directly via launchd. Mirrors the camillagui/camilladsp module pattern.
  launchd.daemons."redis" = lib.mkIf pkgs.stdenv.hostPlatform.isDarwin {
    serviceConfig = {
      # Explicit label to match services.json (which expects local.redis).
      Label = "local.redis";
      # macOS 26+ SIP blocks unsigned Nix store binaries for system daemons
      # with non-root UserName (EX_CONFIG 78). /bin/sh is Apple-signed and
      # ref: macos-service-hardening.instructions.md -- SIP /bin/sh wrapper
      ProgramArguments = [
        "/bin/sh"
        "-c"
        "exec ${pkgs.redis}/bin/redis-server --bind ${redisCfg.host} --port ${toString redisCfg.port} --requirepass \"$(cat ${config.sops.secrets.env_redis_password.path})\" --maxmemory-policy volatile-lru --save '' --appendonly no"
      ];
      KeepAlive = true;
      RunAtLoad = true;
      UserName = username;
      StandardOutPath = "${config.nucleus.logging.systemLogDir}/redis/stdout.log";
      StandardErrorPath = "${config.nucleus.logging.systemLogDir}/redis/stderr.log";
    };
  };

  # NixOS: native multi-server redis module.
  services.redis.servers.nucleus = lib.mkIf pkgs.stdenv.hostPlatform.isLinux {
    enable = true;
    bind = redisCfg.host;
    port = redisCfg.port;
    # Password from SOPS — same pipeline as API keys.
    # nixpkgs renamed passwordFile → masterAuthFile for the multi-server
    # redis module; keep in sync with the MacBook launchd redis invocation
    # (which passes --requirepass from the same SOPS secret).
    masterAuthFile = config.sops.secrets.env_redis_password.path;
    # Eviction: volatile-lru for safe multi-tenant operation.
    settings = {
      maxmemory-policy = "volatile-lru";
    };
  };
}
