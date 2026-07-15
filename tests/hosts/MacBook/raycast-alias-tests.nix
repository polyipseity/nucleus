let
  inherit (import ../../lib.nix) containsRegex;

  macosText = builtins.readFile ../../../src/modules/macos.nix;
  macbookDefaultsText = builtins.readFile ../../../src/hosts/MacBook/defaults.nix;
  macbookManualText = builtins.readFile ../../../src/hosts/MacBook/MANUAL.md;
  raycastManualConfigText = builtins.readFile ../../../src/hosts/MacBook/raycast-manual-config.md;
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
{
  success = true;
  message = "Raycast alias and desktop settings tests passed";
}
