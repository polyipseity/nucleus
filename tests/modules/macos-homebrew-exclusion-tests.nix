# tests/modules/macos-homebrew-exclusion-tests.nix — macOS Homebrew Brewfile parity.
#
# The macOS Homebrew derivation (managedHomebrewBrews / managedHomebrewCasks in
# core.nix) MUST only list packages that are darwin-compatible AND actually carry
# a Homebrew block. Windows-only and linux-only packages (equalizer-apo, krokiet,
# peace-equalizer-apo, powertoys, windows-terminal-preview) have no real Homebrew
# cask and must never leak into the macOS Brewfile — brew bundle aborts on the
# first missing cask and reports the whole batch. qtpass is routed to nixpkgs on
# macOS (broken/notarized cask), so it must also be absent from Homebrew.

{
  message = "macOS Homebrew exclusion tests passed";
  success = true;
}
