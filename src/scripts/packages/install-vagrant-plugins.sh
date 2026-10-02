#!/usr/bin/env bash
# Register the store-provided Vagrant provider plugins in VAGRANT_HOME and verify
# they load. Args: <vagrant-binary> <jq-binary> <vagrant-home> <registry-json>,
# where registry-json is Vagrant's own plugins.json shape:
# {"version": "1", "installed": {"<plugin>": {...}}}.
#
# The gems live in the Nix store and reach Vagrant through GEM_PATH, so the only
# thing to converge is the registry Vagrant reads at startup. A plugin missing
# from `vagrant plugin list` means its gem did not resolve, which fails here
# rather than surfacing as a missing provider during the first `vagrant up`.
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
printf '%s\n' "$_ivp_registry_json" | "$_ivp_jq_bin" -S -c '.installed' >"$_ivp_registry" ||
  die -l vagrant "could not parse the managed Vagrant plugin registry"

_ivp_wanted="$(
  "$_ivp_jq_bin" -r 'keys[]' <"$_ivp_registry" | sort | tr '\n' ' '
)"

mkdir -p "$_ivp_home"
_ivp_state_file="$_ivp_home/plugins.json"

# WHY compare key sets rather than bytes: Vagrant rewrites this file whenever a
# plugin command runs, so formatting is not ours to assert. A plugin that is not
# managed here must not be silently dropped from the registry.
if [ -f "$_ivp_state_file" ]; then
  _ivp_present="$(
    "$_ivp_jq_bin" -S -r '.installed // {} | keys[]' <"$_ivp_state_file" 2>/dev/null |
      sort | tr '\n' ' '
  )"
  [ "$_ivp_present" = "$_ivp_wanted" ] ||
    die -l vagrant "$_ivp_state_file registers unmanaged plugins [$_ivp_present]; remove them with 'vagrant plugin uninstall' before applying"
fi

# shellcheck disable=SC2016 # reason: jq program body must not be expanded by shell
printf '%s\n' "$_ivp_registry_json" |
  "$_ivp_jq_bin" -S -c '{version: "1", installed: .installed}' >"$_ivp_state_file"

_ivp_loaded="$(
  VAGRANT_HOME="$_ivp_home" "$_ivp_vagrant_bin" plugin list 2>/dev/null |
    awk 'NR > 1 { print $1 }' | sort | tr '\n' ' '
)"

while IFS= read -r _ivp_name; do
  case " $_ivp_loaded " in
  *" $_ivp_name "*) ;;
  *) die -l vagrant "the $_ivp_name provider did not load; vagrant reports: $_ivp_loaded" ;;
  esac
done < <("$_ivp_jq_bin" -r 'keys[]' <"$_ivp_registry")

nuc_done "Vagrant providers: $_ivp_wanted"
