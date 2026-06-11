# tests/src/editor-env-vars-tests.nix — Verify $EDITOR/$VISUAL invariants across all hosts.
#
# Ensures every host overrides nix-darwin/NixOS defaults so the active editor
# (neovim / `nvim`) is never silently replaced by the system-level "nano" default.
#
# Run with: nix-instantiate --eval tests/src/editor-env-vars-tests.nix

{ }:
let
  inherit (import ../lib.nix) assert';

  flatten = text: builtins.replaceStrings [ "\n" "\r" ] [ " " " " ] text;
  containsRegex = pattern: haystack: builtins.match ".*${pattern}.*" (flatten haystack) != null;

  macbookBase = builtins.readFile ../../src/hosts/MacBook/base.nix;
  nixosBase = builtins.readFile ../../src/hosts/NixOS/base.nix;
  editorsText = builtins.readFile ../../src/modules/editors.nix;
  windowsDsc = builtins.readFile ../../src/hosts/Windows/user.dsc.yml;

  # --- MacBook (nix-darwin) ---
  # Must override the system-level EDITOR=nano default set by nix-darwin's
  # environment.variables (mkDefault "nano") so that set-environment exports
  # EDITOR=nvim instead of EDITOR=nano. Must use lib.mkForce because a bare
  # "nvim" has the same priority as mkDefault (1000) and causes a
  # duplicate-definition error in Nix module system.
  test_macbook_editor_override = assert' (containsRegex ''environment\.variables\.EDITOR = lib\.mkForce "nvim";'' macbookBase) "MacBook/base.nix must set environment.variables.EDITOR = lib.mkForce \"nvim\" to beat nix-darwin's mkDefault priority";

  # --- NixOS ---
  # Must disable the nano package so NixOS doesn't add an EDITOR=nano default
  # that could interfere with home-manager's neovim defaultEditor.
  test_nixos_nano_disabled = assert' (containsRegex ''programs\.nano\.enable = false;'' nixosBase) "NixOS/base.nix must set programs.nano.enable = false to prevent system-level EDITOR=nano";

  # --- Shared (home-manager / editors.nix) ---
  # The shared editors module must set defaultEditor = true on neovim, which
  # makes home-manager export EDITOR and VISUAL pointing to nvim.
  test_shared_default_editor = assert' (containsRegex ''defaultEditor = true; # sets \$EDITOR and \$VISUAL to nvim'' editorsText) "editors.nix must set defaultEditor = true so home-manager exports EDITOR/VISUAL=nvim";

  # --- Windows ---
  # Windows DSC must set EDITOR environment variable to nvim.
  test_windows_editor = assert' (
    containsRegex "name: EDITOR" windowsDsc && containsRegex "value: nvim" windowsDsc
  ) "Windows user.dsc.yml must set EDITOR environment variable to nvim";

  allTests = [
    test_macbook_editor_override
    test_nixos_nano_disabled
    test_shared_default_editor
    test_windows_editor
  ];
in
{
  success = true;
  testCount = builtins.length allTests;
  message = "All ${toString (builtins.length allTests)} editor env var tests passed";
  testNames = [
    "MacBook EDITOR=nvim override"
    "NixOS nano disabled"
    "Shared defaultEditor = true"
    "Windows EDITOR environment variable"
  ];
}
