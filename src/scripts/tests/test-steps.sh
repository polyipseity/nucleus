#!/usr/bin/env bash
# Dynamic loader for test step files.
# Sources all *.sh files in the test-steps directory.

# shellcheck disable=SC1090 # reason: dynamic glob — checked files are static .sh files individually shellchecked via nix build
_self="${BASH_SOURCE[0]:-$0}"
STEP_DIR="$(CDPATH='' cd -- "$(dirname -- "$_self")" && pwd)/test-steps"
for _step_file in "$STEP_DIR"/*.sh; do
  . "$_step_file"
done
