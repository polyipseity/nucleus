# General-purpose loopback Redis service for all hosts.
#
# Redis is a generic in-memory data store used for cross-service coordination
# and caching (LiteLLM is one consumer, but the service itself is not AI-
# specific). This module owns the Redis server definition on macOS and NixOS;
# Windows provisions the equivalent native SCM service via
# src/platforms/Windows/modules/system/Sync-RedisService.ps1.
#
# Authentication uses Redis ACL files (runtime-generated from decrypted SOPS
# secrets, not in the Nix store). Two users are defined:
#   - default: admin user, full access (password from env_redis_password)
#   - litellm: scoped user for the LiteLLM proxy (password from
#     env_redis_user_litellm_password), with key/channel access limited to
#     ~litellm:* / &litellm:* and all commands except @admin.
#
# The endpoint (host/port) comes from the centralized service registry
# (src/modules/services.json). Passwords are exposed to consumers as
# REDIS_PASSWORD and REDIS_USER_LITELLM_PASSWORD by the shared env catalog
# (src/modules/env-catalog.nix).
{
  config,
  lib,
  options,
  pkgs,
  username,
  ...
}:
let
  # Centralized service registry — single source of truth for network config.
  servicesJSON = builtins.fromJSON (builtins.readFile ./services.json);
  redisCfg = servicesJSON.redis.network.default;

  # The `launchd` option only exists on nix-darwin; `services.redis` only on
  # NixOS. Gate each subtree with optionalAttrs so the inactive option path is
  # never declared (a bare `mkIf false` would still register the option and
  # fail on the other platform). Mirrors posix-base.nix hasLaunchdDaemonsOption.
  hasLaunchdDaemonsOption = options ? launchd && options.launchd ? daemons;
  hasRedisServersOption =
    options ? services && options.services ? redis && options.services.redis ? servers;
in
{
  config = lib.mkMerge [
    # macOS: nix-darwin has no services.redis module, so run redis-server
    # directly via launchd. Mirrors the camillagui/camilladsp module pattern.
    # The whole `launchd.daemons` subtree is gated by optionalAttrs so the
    # `launchd` option path is never declared on NixOS (where it does not exist).
    (lib.optionalAttrs hasLaunchdDaemonsOption {
      launchd.daemons."redis" = {
        serviceConfig = {
          # Explicit label to match services.json (which expects local.redis).
          Label = "local.redis";
          # macOS 26+ SIP blocks unsigned Nix store binaries for system daemons
          # with non-root UserName (EX_CONFIG 78). /bin/sh is Apple-signed and
          # ref: macos-service-hardening.instructions.md -- SIP /bin/sh wrapper
          ProgramArguments = [
            "/bin/sh"
            "-c"
            ''
              _acl_dir="/Library/Application Support/nucleus/redis"
              mkdir -p "$_acl_dir"
              _acl_file="$_acl_dir/users.acl"
              _default_pw=$(cat ${config.sops.secrets.env_redis_password.path})
              _litellm_pw=$(cat ${config.sops.secrets.env_redis_user_litellm_password.path})
              cat > "$_acl_file" <<ACL_EOF
              # Managed by nucleus. Do not edit by hand.
              # Generated from SOPS secrets at service-start time.
              user default on >$_default_pw ~* &* +@all
              user litellm on >$_litellm_pw ~litellm:* &litellm:* +@all -@admin
              ACL_EOF
              chmod 0640 "$_acl_file"
              exec ${pkgs.redis}/bin/redis-server --bind ${redisCfg.host} --port ${toString redisCfg.port} --aclfile "$_acl_file" --maxmemory-policy volatile-lru --save "" --appendonly no
            ''
          ];
          KeepAlive = true;
          RunAtLoad = true;
          UserName = username;
          StandardOutPath = "${config.nucleus.logging.systemLogDir}/redis/stdout.log";
          StandardErrorPath = "${config.nucleus.logging.systemLogDir}/redis/stderr.log";
        };
      };
    })

    # NixOS: native multi-server redis module.
    (lib.optionalAttrs hasRedisServersOption {
      services.redis.servers.nucleus = {
        enable = true;
        bind = redisCfg.host;
        port = redisCfg.port;
        # Eviction: volatile-lru for safe multi-tenant operation.
        settings = {
          maxmemory-policy = "volatile-lru";
          aclfile = "/var/lib/redis-nucleus/users.acl";
        };
      };
      # Generate ACL file at service-start from decrypted SOPS secrets.
      # The redis module creates StateDirectory=redis-nucleus (/var/lib/redis-nucleus)
      # owned by the service user; preStart runs as that user before redis-server.
      systemd.services.redis-nucleus.preStart = lib.mkAfter ''
        _default_pw=$(cat ${config.sops.secrets.env_redis_password.path})
        _litellm_pw=$(cat ${config.sops.secrets.env_redis_user_litellm_password.path})
        cat > /var/lib/redis-nucleus/users.acl <<ACL_EOF
        # Managed by nucleus. Do not edit by hand.
        # Generated from SOPS secrets at service-start time.
        user default on >$_default_pw ~* &* +@all
        user litellm on >$_litellm_pw ~litellm:* &litellm:* +@all -@admin
        ACL_EOF
        chmod 0640 /var/lib/redis-nucleus/users.acl
      '';
    })
  ];
}
