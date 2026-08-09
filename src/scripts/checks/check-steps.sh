# shellcheck shell=bash
# Dynamic loader for check step files.
# Sources all *.sh files in the check-steps directory.
# Eval emits literal `. ./NN-name.sh` lines so BASH_SOURCE resolves in each step.

_self="${BASH_SOURCE[0]:-$0}"
_CHECKS_DIR="$(CDPATH='' cd -- "$(dirname -- "$_self")" && pwd)"
# shellcheck disable=SC2016 # reason: eval body must emit literal dot-source lines for BASH_SOURCE
eval "$({
  printf 'cd %q || exit\n' "$_CHECKS_DIR/check-steps"
  for _step_file in "$_CHECKS_DIR/check-steps"/*.sh; do
    [ -f "$_step_file" ] || continue
    printf '. ./%q\n' "$(basename "$_step_file")"
  done
})"
