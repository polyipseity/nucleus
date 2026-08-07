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
    generationsKeep = lib.mkOption {
      type = lib.types.ints.positive;
      default = 7;
      description = "Master generation-count override. Per-scope options win.";
    };
    systemGenerationsKeep = lib.mkOption {
      type = lib.types.ints.positive;
      default = config.modules.gc.generationsKeep;
      defaultText = lib.literalExpression "config.modules.gc.generationsKeep";
      description = "Newest system profile generations to retain (intersection with age expiry). Defaults to the master generationsKeep value.";
    };
    hmGenerationsKeep = lib.mkOption {
      type = lib.types.ints.positive;
      default = config.modules.gc.generationsKeep;
      defaultText = lib.literalExpression "config.modules.gc.generationsKeep";
      description = "Newest Home Manager profile generations to retain (intersection with age expiry). Defaults to the master generationsKeep value.";
    };
  };
}
