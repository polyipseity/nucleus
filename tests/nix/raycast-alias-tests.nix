let
  flatten = text: builtins.replaceStrings [ "\n" "\r" ] [ " " " " ] text;

  containsRegex = pattern: haystack: builtins.match ".*${pattern}.*" (flatten haystack) != null;

  macosText = builtins.readFile ../../src/modules/macos.nix;
  macbookDefaultsText = builtins.readFile ../../src/hosts/macbook/defaults.nix;
  macbookManualText = builtins.readFile ../../src/hosts/macbook/MANUAL.md;
  raycastManualConfigText = builtins.readFile ../../src/hosts/macbook/raycast-manual-config.md;
in
assert containsRegex "configureRaycastApplicationAliases" macosText;
assert containsRegex "Nucleus App Aliases" macosText;
assert containsRegex "Books \\(English\\)\\.app" macosText;
assert containsRegex "Messages \\(English\\)\\.app" macosText;
assert containsRegex "Weather \\(English\\)\\.app" macosText;
assert containsRegex ''"com\.raycast\.macos"'' macbookDefaultsText;
assert !containsRegex "NSUserKeyEquivalents" macbookDefaultsText;
assert containsRegex "Clipboard History hotkey" macbookManualText;
assert containsRegex "Clipboard History" raycastManualConfigText;
assert containsRegex "⌥⌘C" raycastManualConfigText;
assert containsRegex "DesktopViewSettings" macbookDefaultsText;
assert containsRegex ''arrangeBy = "grid"'' macbookDefaultsText;
true
