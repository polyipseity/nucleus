let
  inherit (import ../lib.nix) flatten containsRegex;

  envVarsText = builtins.readFile ../../src/modules/lib/env-vars.nix;
  windowsSystemDscText = builtins.readFile ../../src/hosts/Windows/system/env.dsc.yml;
  rootOpenCodeConfigText = builtins.readFile ../../opencode.jsonc;
  userOpenCodeConfigText = builtins.readFile ../../src/modules/configs/agents/opencode.user.jsonc;
in
assert containsRegex "OPENCODE_DISABLE_AUTOUPDATE" envVarsText;
assert containsRegex "OPENCODE_DISABLE_AUTOUPDATE" windowsSystemDscText;
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
assert !containsRegex "OPENCODE_NO_UPDATE_CHECK" envVarsText;
assert !containsRegex "OPENCODE_NO_UPDATE_CHECK" windowsSystemDscText;
{
  success = true;
  message = "OpenCode configuration parity tests passed";
}
