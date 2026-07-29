#!/usr/bin/env bash
# Dynamic loader for check step files.
# Sources all *.sh files in the check-steps directory.

# shellcheck disable=SC1090 # reason: dynamic glob — checked files are static .sh files individually shellchecked via nix build
STEP_DIR="$(CDPATH='' cd -- "$(dirname "$0")" && pwd)/check-steps"
for _step_file in "$STEP_DIR"/*.sh; do
  . "$_step_file"
done
