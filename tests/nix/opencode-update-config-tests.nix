let
  flatten = text: builtins.replaceStrings [ "\n" "\r" ] [ " " " " ] text;

  containsRegex = pattern: haystack: builtins.match ".*${pattern}.*" (flatten haystack) != null;

  shellEnvText = builtins.readFile ../../src/modules/shell/env.nix;
  nixosBaseText = builtins.readFile ../../src/hosts/nixos/base.nix;
  windowsUserDscText = builtins.readFile ../../src/hosts/windows/user.dsc.yml;
  rootOpenCodeConfigText = builtins.readFile ../../opencode.jsonc;
  userOpenCodeConfigText = builtins.readFile ../../src/modules/configs/agents/opencode.user.jsonc;
in
assert containsRegex "OPENCODE_DISABLE_AUTOUPDATE" shellEnvText;
assert containsRegex "OPENCODE_DISABLE_AUTOUPDATE" nixosBaseText;
assert containsRegex "OPENCODE_DISABLE_AUTOUPDATE" windowsUserDscText;
assert containsRegex "\"autoupdate\"[[:space:]]*:[[:space:]]*false" rootOpenCodeConfigText;
assert containsRegex "\"autoupdate\"[[:space:]]*:[[:space:]]*false" userOpenCodeConfigText;
assert !containsRegex "OPENCODE_NO_UPDATE_CHECK" shellEnvText;
assert !containsRegex "OPENCODE_NO_UPDATE_CHECK" nixosBaseText;
assert !containsRegex "OPENCODE_NO_UPDATE_CHECK" windowsUserDscText;
true
