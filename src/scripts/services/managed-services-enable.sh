#!/usr/bin/env bash
# Clear service enable gates for managed live instances without starting them.
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=../lib/bash-guard.sh
. "$SCRIPT_DIR/../lib/bash-guard.sh"
# shellcheck source=../lib/service-targets.sh
. "$SCRIPT_DIR/../lib/service-targets.sh"

bash_guard_require 5 1 managed-services-enable

_registry="$1"
_host="$2"
_svc_script="$3"

_targets="$(service_targets_for_host "$_registry" "$_host")"
while IFS= read -r _target; do
  [ -n "$_target" ] || continue
  "$_svc_script" enable "$_target"
done <<<"$_targets"
