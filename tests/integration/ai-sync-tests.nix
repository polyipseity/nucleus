let
  inherit (import ../lib.nix) containsRegex flatten;

  aiSyncText = builtins.readFile ../../scripts/ai-sync.sh;
  flakeText = builtins.readFile ../../src/flake.nix;
  gcText = builtins.readFile ../../scripts/gc.sh;
  coreText = builtins.readFile ../../src/modules/core.nix;
  defaultAiText = builtins.readFile ../../src/modules/ai/default.nix;
  nixosAiText = builtins.readFile ../../src/hosts/NixOS/ai.nix;
  litellmConfigText = builtins.readFile ../../src/modules/ai/litellm-config.yml;
  secretsText = builtins.readFile ../../src/modules/secrets.nix;
  macbookAiText = builtins.readFile ../../src/hosts/MacBook/ai.nix;
in
assert containsRegex "pkgs.jq" flakeText;
assert containsRegex "pkgs.litellm" coreText;
assert containsRegex "NUCLEUS_AI_SYNC_TIMEOUT" aiSyncText;
assert containsRegex "waiting up to" aiSyncText;
assert containsRegex "dry_run=false" aiSyncText;
assert containsRegex "gc_only=false" aiSyncText;
assert containsRegex "NUCLEUS_AI_SYNC_TIMEOUT=0" gcText;
# GC script expiry & dry-run assertions
assert containsRegex "dry_run=false" gcText;
assert containsRegex "expiry_arg=\"\"" gcText;
assert containsRegex "hm_expiry_arg=\"\"" gcText;
assert containsRegex "nix_expiry_arg=\"\"" gcText;
assert containsRegex "hm_expiry=" gcText;
assert containsRegex "nix_expiry=" gcText;
assert containsRegex "hm_expiry_hm_format" gcText;
# LiteLLM gateway assertions
assert containsRegex "litellm" coreText;
assert containsRegex "OPENROUTER_API_KEY" litellmConfigText;
assert containsRegex "127.0.0.1:11434" aiSyncText;
# OLLAMA_HOST is now defined in src/modules/lib/env-vars.nix, not default.nix
assert containsRegex "local.litellm" macbookAiText;
assert containsRegex "ai_openrouter_api_key" secretsText;
assert containsRegex "ai_opencode_zen_api_key" secretsText;
assert containsRegex "opencode.ai/zen/v1" litellmConfigText;
assert containsRegex "systemd.services.litellm" nixosAiText;
{
  success = true;
  message = "AI model sync configuration tests passed";
}
