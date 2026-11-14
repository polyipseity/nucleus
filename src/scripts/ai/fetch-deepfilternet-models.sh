#!/usr/bin/env bash
# Deploy the DeepFilterNet3 ONNX weights pinned in the lockfile's
# `deepfilternet` section into <nucleus USER root>/models.
#
# The weights are a pkgs.fetchurl derivation, so the store already enforced the
# pinned hash at build time. This script only deploys: it compares the SHA-256
# of the deployed copy against the store source and rewrites on a mismatch.
#
# WHY a copy rather than a symlink into /nix/store: a symlink under a home
# directory is not a GC root, so nix-collect-garbage can delete the store path
# and leave the link dangling. These weights are user data, not build output.
#
# Usage: fetch-deepfilternet-models.sh <model-dir> <sha256sum-bin> <jq-bin> <models-json>
#   models-json: [{"file": "<name>", "source": "<store path>"}, ...]

set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=../lib/lib.sh
. "$SCRIPT_DIR/../lib/lib.sh"

_fdm_model_dir="$1"
_fdm_sha256sum_bin="$2"
_fdm_jq_bin="$3"
_fdm_models_json="$4"

mkdir -p "$_fdm_model_dir"

_fdm_hash_of() {
  "$_fdm_sha256sum_bin" "$1" | cut -d' ' -f1
}

# WHY: mapfile plus a loop, not a pipe into `while read`: a pipeline body runs
# in a subshell, so `die` inside it would exit only that subshell and the
# activation would continue past the failure.
# shellcheck disable=SC2016 # reason: the jq program is single-quoted on purpose
mapfile -t _fdm_entries < <(printf '%s' "$_fdm_models_json" | "$_fdm_jq_bin" -r '.[] | [.file, .source] | @tsv')

for _fdm_entry in "${_fdm_entries[@]}"; do
  _fdm_file="${_fdm_entry%%	*}"
  _fdm_source="${_fdm_entry#*	}"

  if [ ! -f "$_fdm_source" ]; then
    die -l deepfilternet "model source missing at $_fdm_source: the fetchurl derivation was not realised"
  fi

  _fdm_target="$_fdm_model_dir/$_fdm_file"
  if [ -f "$_fdm_target" ] && [ "$(_fdm_hash_of "$_fdm_target")" = "$(_fdm_hash_of "$_fdm_source")" ]; then
    say -l deepfilternet "$_fdm_file already current"
    continue
  fi

  install -m 644 "$_fdm_source" "$_fdm_target"
  say -l deepfilternet "deployed $_fdm_file"
done

nuc_done -l deepfilternet
