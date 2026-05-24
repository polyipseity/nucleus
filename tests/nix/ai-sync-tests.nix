let
  flatten = text: builtins.replaceStrings [ "\n" "\r" ] [ " " " " ] text;

  containsRegex = pattern: haystack: builtins.match ".*${pattern}.*" (flatten haystack) != null;

  aiSyncText = builtins.readFile ../../scripts/AI-sync.sh;
  flakeText = builtins.readFile ../../src/flake.nix;
  gcText = builtins.readFile ../../scripts/gc.sh;
in
assert containsRegex "pkgs.jq" flakeText;
assert containsRegex "OLLAMA_READY_TIMEOUT_SECONDS" aiSyncText;
assert containsRegex "waiting up to" aiSyncText;
assert containsRegex "dry_run=false" aiSyncText;
assert containsRegex "prune_only=false" aiSyncText;
assert containsRegex "OLLAMA_READY_TIMEOUT_SECONDS=0" gcText;
true
