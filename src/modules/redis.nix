# General-purpose loopback Redis service for all hosts.
#
# Redis server for macOS and NixOS; Windows provisions the SCM twin in
# src/platforms/Windows/modules/system/Sync-RedisService.ps1
#
# The ACL file is generated at service start from decrypted SOPS secrets, so it
# never lands in the Nix store. Two users: default (admin, env_redis_password)
# and litellm (scoped to ~litellm:* and &litellm:*, every command except
# @admin, env_redis_user_litellm_password).
#
# The endpoint (host/port) comes from the centralized service registry
# (src/modules/services.json). Passwords are exposed to consumers as
# REDIS_PASSWORD and REDIS_USER_LITELLM_PASSWORD by the shared env catalog
# (src/modules/env/env-secrets.json).
{
  config,
  lib,
  options,
  pkgs,
  username,
  ...
}:
let
  # The endpoint comes from src/modules/services.json.
  servicesJSON = builtins.fromJSON (builtins.readFile ./services.json);
  redisCfg = servicesJSON.redis.network.default;

  # Gate each subtree so an option that does not exist on this platform is
  # never declared: a bare `mkIf false` still registers it and fails to build.
  hasLaunchdDaemonsOption = options ? launchd && options.launchd ? daemons;
  hasRedisServersOption =
    options ? services && options.services ? redis && options.services.redis ? servers;
in
{
  config = lib.mkMerge [
    # nix-darwin has no services.redis module, so run redis-server via launchd.
    (lib.optionalAttrs hasLaunchdDaemonsOption {
      launchd.daemons."redis" = {
        serviceConfig = {
          # services.json expects local.redis.
          Label = "local.redis";
          # macOS 26+ SIP blocks unsigned store binaries for system daemons with
          # non-root UserName (EX_CONFIG 78); /bin/sh is Apple-signed.
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
        # volatile-lru so an evicted key is one the user set with a TTL.
        settings = {
          maxmemory-policy = "volatile-lru";
          aclfile = "/var/lib/redis-nucleus/users.acl";
        };
      };
      # StateDirectory=redis-nucleus is owned by the service user, and preStart
      # runs as that user before redis-server.
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
