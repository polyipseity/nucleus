# Shared GC expiry options for system and Home Manager modules.
{ config, lib, ... }:
{
  options.modules.gc = {
    expiry = lib.mkOption {
      type = lib.types.str;
      default = "7d";
      description = "Master expiry override. Per-tool options win.";
    };
    nixStoreExpiry = lib.mkOption {
      type = lib.types.str;
      default = config.modules.gc.expiry;
      defaultText = lib.literalExpression "config.modules.gc.expiry";
      description = "Duration for nix-collect-garbage --delete-older-than. Defaults to the master expiry value.";
    };
  };
}
