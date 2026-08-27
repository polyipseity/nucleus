# Static assertions for shell-quoting of spaced paths in MacBook
# linux-builder.nix activation scripts.
#
# Regression guard: a path containing a space ("Application Support") must be
# quoted inside a Nix indented string so the shell does not word-split it. An
# unquoted ${workDir} makes `nucleus-apply` (darwin-rebuild switch) fail with
# "mkdir: cannot create directory 'Support': Read-only file system".

let
  lib = import <nixpkgs/lib>;

  linuxBuilderNix = builtins.readFile ../../../src/hosts/MacBook/linux-builder.nix;
  # Quoted form as it appears in the Nix source (literal "${workDir}").
  # Build from parts so Nix does not interpolate the ${workDir} reference.
  quoted = ''"'' + "$" + "{workDir}" + ''"'';
  # Dangerous, word-splitting form: an unquoted ${workDir} as a mkdir argument.
  # Build from parts so Nix does not interpolate the ${workDir} reference.
  unquotedMkdir = "mkdir -p " + "$" + "{workDir}";
in

assert lib.hasInfix quoted linuxBuilderNix;
assert !lib.hasInfix unquotedMkdir linuxBuilderNix;

{
  success = true;
  message = "linux-builder shell-quoting tests passed";
}
