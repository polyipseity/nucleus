# Static assertions for shell-variable escaping in MacBook activation.nix.
#
# Regression guard: a shell variable referenced inside a Nix indented string
# must be escaped as ''${VAR} so Nix does not try to interpolate it at eval
# time. An unescaped ${_console_user} makes `nucleus-apply` (darwin-rebuild
# switch) fail with "undefined variable '_console_user'".

let
  lib = import <nixpkgs/lib>;

  activationNix = builtins.readFile ../../../src/hosts/MacBook/activation.nix;
  # Escaped form as it appears in the Nix source (literal ''${_console_user}).
  # Build it from parts: two single quotes + "${_console_user}".
  escaped = "'" + "'" + "$" + "{_console_user}";
  # Bare form that would re-introduce the eval error (literal ${_console_user}).
  unescaped = "$" + "{_console_user}";
  # Remove every escaped occurrence, then check none of the bare form remain.
  withoutEscaped = lib.replaceStrings [ escaped ] [ "" ] activationNix;
in

assert lib.hasInfix escaped activationNix;
assert !lib.hasInfix unescaped withoutEscaped;

{
  success = true;
  message = "activation shell-variable escaping tests passed";
}
