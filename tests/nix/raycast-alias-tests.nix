let
  flatten = text: builtins.replaceStrings [ "\n" "\r" ] [ " " " " ] text;

  containsRegex = pattern: haystack: builtins.match ".*${pattern}.*" (flatten haystack) != null;

  macosText = builtins.readFile ../../src/modules/macos.nix;
in
assert containsRegex "configureRaycastApplicationAliases" macosText;
assert containsRegex "Nucleus App Aliases" macosText;
assert containsRegex "Books \\(English\\)\\.app" macosText;
assert containsRegex "Messages \\(English\\)\\.app" macosText;
assert containsRegex "Weather \\(English\\)\\.app" macosText;
true
