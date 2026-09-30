#!/usr/bin/env bash
# Deploy the ggml speech-to-text weights pinned in the lockfile's `whisper`
# section into <nucleus USER root>/models.
#
# The weights are a pkgs.fetchurl derivation, so the Nix store already enforced
# the pinned hash at build time. This script only deploys and stays idempotent:
# it compares the SHA-256 of the deployed copy with the SHA-256 of the store
# source and rewrites the copy when they differ.
#
# WHY a copy rather than a symlink into /nix/store: a plain symlink under a home
# directory is not a GC root, so nix-collect-garbage can delete the store path
# and leave the link dangling. These weights are user data, not build output.
#
# Usage: fetch-whisper-models.sh <model-dir> <sha256sum-bin> <jq-bin> <models-json>
#   models-json: [{"file": "<name>", "source": "<store path>"}, ...]

set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=../lib/lib.sh
. "$SCRIPT_DIR/../lib/lib.sh"

_fwm_model_dir="$1"
_fwm_sha256sum_bin="$2"
_fwm_jq_bin="$3"
_fwm_models_json="$4"

mkdir -p "$_fwm_model_dir"

_fwm_hash_of() {
  "$_fwm_sha256sum_bin" "$1" | cut -d' ' -f1
}

# Read the entries with mapfile and loop over the array rather than piping into
# `while read`: a pipeline body runs in a subshell, so `die` inside it would
# exit only that subshell and the activation would continue past the failure.
# shellcheck disable=SC2016 # reason: the jq program is single-quoted on purpose
mapfile -t _fwm_entries < <(printf '%s' "$_fwm_models_json" | "$_fwm_jq_bin" -r '.[] | [.file, .source] | @tsv')

for _fwm_entry in "${_fwm_entries[@]}"; do
  _fwm_file="${_fwm_entry%%	*}"
  _fwm_source="${_fwm_entry#*	}"

  if [ ! -f "$_fwm_source" ]; then
    die -l whisper "model source missing at $_fwm_source: the fetchurl derivation was not realised"
  fi

  _fwm_target="$_fwm_model_dir/$_fwm_file"
  if [ -f "$_fwm_target" ] && [ "$(_fwm_hash_of "$_fwm_target")" = "$(_fwm_hash_of "$_fwm_source")" ]; then
    say -l whisper "$_fwm_file already current"
    continue
  fi

  install -m 644 "$_fwm_source" "$_fwm_target"
  say -l whisper "deployed $_fwm_file"
done

nuc_done -l whisper
