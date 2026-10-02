#!/usr/bin/env bash
# Write the managed Vagrant provider registry into VAGRANT_HOME and verify that
# Vagrant reports every provider at its pinned version.
#
# Args: <vagrant-binary> <jq-binary> <vagrant-home> <registry-json>, where the
# registry is Vagrant's own plugins.json shape:
#   {"version": "1", "installed": {"<plugin>": {ruby_version, gem_version, ...}}}
#
# The gems themselves come from the Nix store through the wrapper's GEM_PATH, so
# nothing is fetched here. A provider Vagrant cannot resolve is reported here
# instead of surfacing later as an unusable provider during `vagrant up`.
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=../lib/lib.sh
. "$SCRIPT_DIR/../lib/lib.sh"

_ivp_vagrant_bin="$1"
_ivp_jq_bin="$2"
_ivp_home="$3"
_ivp_registry_json="$4"

[ -x "$_ivp_vagrant_bin" ] || die -l vagrant "vagrant is not executable at $_ivp_vagrant_bin"

_ivp_registry="$(mktemp)"
# shellcheck disable=SC2016 # reason: jq program body must not be expanded by shell
printf '%s\n' "$_ivp_registry_json" |
  "$_ivp_jq_bin" -S -c 'if (.installed // {} | length) == 0 then error("no providers declared") else .installed end' \
    >"$_ivp_registry" || die -l vagrant "the managed Vagrant provider registry declares no providers"

_ivp_wanted="$("$_ivp_jq_bin" -r 'to_entries[] | "\(.key) \(.value.gem_version)"' <"$_ivp_registry")"

mkdir -p "$_ivp_home"
_ivp_state_file="$_ivp_home/plugins.json"

# WHY compare key sets and not bytes: Vagrant rewrites this file whenever a
# plugin command runs, so its formatting is not ours to assert. A provider that
# is not managed here must not be dropped from the registry.
if [ -f "$_ivp_state_file" ]; then
  _ivp_present="$(
    "$_ivp_jq_bin" -S -r '.installed // {} | keys | join(" ")' <"$_ivp_state_file" 2>/dev/null
  )"
  _ivp_managed="$("$_ivp_jq_bin" -r 'keys | join(" ")' <"$_ivp_registry")"
  [ "$_ivp_present" = "$_ivp_managed" ] ||
    die -l vagrant "$_ivp_state_file registers providers this repo does not manage [$_ivp_present]; remove them with 'vagrant plugin uninstall' before applying"
fi

# shellcheck disable=SC2016 # reason: jq program body must not be expanded by shell
printf '%s\n' "$_ivp_registry_json" |
  "$_ivp_jq_bin" -S -c '.' >"$_ivp_state_file"

_ivp_installed="$(
  VAGRANT_HOME="$_ivp_home" "$_ivp_vagrant_bin" plugin list 2>/dev/null |
    awk '$1 ~ /^[A-Za-z][A-Za-z0-9_-]*$/ && $2 ~ /^\(/ { gsub(/[(),]/, "", $2); print $1, $2 }' |
    tr '\n' ' '
)"

while IFS=' ' read -r _ivp_name _ivp_version; do
  case " $_ivp_installed " in
  *" $_ivp_name $_ivp_version "*) ;;
  *) die -l vagrant "provider $_ivp_name $_ivp_version did not load; vagrant reports: ${_ivp_installed:-none}" ;;
  esac
done <<<"$_ivp_wanted"

nuc_done "Vagrant providers: $("$_ivp_jq_bin" -r 'keys | join(", ")' <"$_ivp_registry")"
