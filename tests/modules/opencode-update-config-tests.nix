let
  flatten = text: builtins.replaceStrings [ "\n" "\r" ] [ " " " " ] text;

  containsRegex = pattern: haystack: builtins.match ".*${pattern}.*" (flatten haystack) != null;

  shellEnvText = builtins.readFile ../../src/modules/shell/env.nix;
  nixosBaseText = builtins.readFile ../../src/hosts/NixOS/base.nix;
  windowsUserDscText = builtins.readFile ../../src/hosts/Windows/user/env.dsc.yml;
  rootOpenCodeConfigText = builtins.readFile ../../opencode.jsonc;
  userOpenCodeConfigText = builtins.readFile ../../src/modules/configs/agents/opencode.user.jsonc;
in
assert containsRegex "OPENCODE_DISABLE_AUTOUPDATE" shellEnvText;
assert containsRegex "OPENCODE_DISABLE_AUTOUPDATE" nixosBaseText;
assert containsRegex "OPENCODE_DISABLE_AUTOUPDATE" windowsUserDscText;
assert containsRegex "\"autoupdate\"[[:space:]]*:[[:space:]]*false" rootOpenCodeConfigText;
assert containsRegex "\"autoupdate\"[[:space:]]*:[[:space:]]*false" userOpenCodeConfigText;
assert containsRegex "\"instructions\"[[:space:]]*:[[:space:]]*" rootOpenCodeConfigText;
assert containsRegex "\"instructions\"[[:space:]]*:[[:space:]]*" userOpenCodeConfigText;
assert containsRegex "[.]agents/instructions" rootOpenCodeConfigText;
assert containsRegex "[.]agents/instructions" userOpenCodeConfigText;
assert containsRegex "\"skills\"[[:space:]]*:[[:space:]]*" rootOpenCodeConfigText;
assert containsRegex "\"skills\"[[:space:]]*:[[:space:]]*" userOpenCodeConfigText;
assert containsRegex "\"paths\"[[:space:]]*:[[:space:]]*" rootOpenCodeConfigText;
assert containsRegex "\"paths\"[[:space:]]*:[[:space:]]*" userOpenCodeConfigText;
assert containsRegex "[.]agents/skills" rootOpenCodeConfigText;
assert containsRegex "[.]agents/skills" userOpenCodeConfigText;
assert !containsRegex "OPENCODE_NO_UPDATE_CHECK" shellEnvText;
assert !containsRegex "OPENCODE_NO_UPDATE_CHECK" nixosBaseText;
assert !containsRegex "OPENCODE_NO_UPDATE_CHECK" windowsUserDscText;
{
  success = true;
  message = "OpenCode configuration parity tests passed";
}
