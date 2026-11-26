#!/usr/bin/env bash
# Merge LiteLLM model slots into harness configs whose install directory exists.
# Args: <python3> <jq> <repo-root> <registry> <host> <home>
# Exit: non-zero only when python, the registry, or the merge tool is missing,
# or when the merge itself fails. A harness with no config directory is skipped.
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=../lib/bash-guard.sh
. "$SCRIPT_DIR/../lib/bash-guard.sh"
bash_guard_require 5 1 provision-harness-models
# shellcheck source=../lib/lib.sh
. "$SCRIPT_DIR/../lib/lib.sh"

_pm_python_bin="$1"
_pm_jq_bin="$2"
_pm_repo_root="$3"
_pm_registry="$4"
_pm_host="$5"
_pm_home="$6"

if [ ! -x "$_pm_python_bin" ]; then
  die -l harness-models "python interpreter not found: $_pm_python_bin"
fi
if [ ! -f "$_pm_registry" ]; then
  die -l harness-models "registry not found: $_pm_registry"
fi
if [ ! -f "$SCRIPT_DIR/merge-harness-models.py" ]; then
  die -l harness-models "merge tool not found: $SCRIPT_DIR/merge-harness-models.py"
fi

_pm_targets="$("$_pm_jq_bin" -r --arg host "$_pm_host" --arg home "$_pm_home" "
  def expand_home: if startswith(\"~/\") then (\$home + \"/\" + .[2:]) else . end;
  .harnesses[] |
  [.harness, ((if (.path | type) == \"object\" then (.path[\$host] // \"\") else .path end) | expand_home)] |
  @tsv
" "$_pm_registry")"

_pm_installed=()
while IFS=$'\t' read -r _pm_id _pm_config_file; do
  [ -n "$_pm_id" ] || continue
  if [ -z "$_pm_config_file" ]; then
    die -l harness-models "registry has no config path for host '$_pm_host' (harness '$_pm_id')"
  fi
  _pm_config_dir="$(dirname -- "$_pm_config_file")"
  if [ ! -d "$_pm_config_dir" ]; then
    # WHY: a harness whose install is disabled has no config directory. Creating one here would leave an empty stub that makes that harness look configured.
    notice -l harness-models "skipped $_pm_id: no config directory $_pm_config_dir"
    continue
  fi
  _pm_installed+=("$_pm_id")
done <<<"$_pm_targets"

if [ "${#_pm_installed[@]}" -eq 0 ]; then
  notice -l harness-models "no installed harness config directories; skipped model provisioning"
  exit 0
fi

_pm_merge_args=(
  "$SCRIPT_DIR/merge-harness-models.py"
  --registry "$_pm_registry"
  --repo-root "$_pm_repo_root"
  --home "$_pm_home"
  --host "$_pm_host"
)
for _pm_id in "${_pm_installed[@]}"; do
  _pm_merge_args+=(--harness "$_pm_id")
done
"$_pm_python_bin" "${_pm_merge_args[@]}"
nuc_done -l harness-models
