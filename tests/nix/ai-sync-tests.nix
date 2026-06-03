let
  flatten = text: builtins.replaceStrings [ "\n" "\r" ] [ " " " " ] text;

  containsRegex = pattern: haystack: builtins.match ".*${pattern}.*" (flatten haystack) != null;

  aiSyncText = builtins.readFile ../../scripts/ai-sync.sh;
  flakeText = builtins.readFile ../../src/flake.nix;
  gcText = builtins.readFile ../../scripts/gc.sh;
  coreText = builtins.readFile ../../src/modules/core.nix;
  defaultAiText = builtins.readFile ../../src/modules/ai/default.nix;
  nixosAiText = builtins.readFile ../../src/hosts/NixOS/ai.nix;
  litellmConfigText = builtins.readFile ../../src/modules/ai/litellm-config.yml;
  secretsText = builtins.readFile ../../src/modules/secrets.nix;
in
assert containsRegex "pkgs.jq" flakeText;
assert containsRegex "pkgs.litellm" coreText;
assert containsRegex "server-ready-timeout-seconds" aiSyncText;
assert containsRegex "waiting up to" aiSyncText;
assert containsRegex "dry_run=false" aiSyncText;
assert containsRegex "prune_only=false" aiSyncText;
assert containsRegex "server-ready-timeout-seconds 0" gcText;
# LiteLLM gateway assertions
assert containsRegex "litellm" coreText;
assert containsRegex "OPENROUTER_API_KEY" litellmConfigText;
assert containsRegex "127.0.0.1:11434" aiSyncText;
assert containsRegex "OLLAMA_HOST.*127.0.0.1:4000" defaultAiText;
assert containsRegex "local.litellm" defaultAiText;
assert containsRegex "ai_openrouter_api_key" secretsText;
assert containsRegex "systemd.services.litellm" nixosAiText;
true
