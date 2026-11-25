#!/usr/bin/env bash
# Refresh the pinned nix-index database.
# CLI args: model_dir sha256sum_bin jq_bin lockfile
# Env var fallbacks: NIX_INDEX_MODEL_DIR, NIX_INDEX_SHA256SUM, NIX_INDEX_JQ, NIX_INDEX_LOCKFILE
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=../lib/bash-guard.sh
. "$SCRIPT_DIR/../lib/bash-guard.sh"
bash_guard_require 5 1 update-nix-index
# shellcheck source=../lib/lib.sh
. "$SCRIPT_DIR/../lib/lib.sh"

_uni_model_dir="${NIX_INDEX_MODEL_DIR:-${1:?usage: update-nix-index.sh <model_dir> <sha256sum_bin> <jq_bin> <lockfile>}}"
_uni_sha256sum_bin="${NIX_INDEX_SHA256SUM:-${2:?usage: update-nix-index.sh <model_dir> <sha256sum_bin> <jq_bin> <lockfile>}}"
_uni_jq_bin="${NIX_INDEX_JQ:-${3:?usage: update-nix-index.sh <model_dir> <sha256sum_bin> <jq_bin> <lockfile>}}"
_uni_lockfile="${NIX_INDEX_LOCKFILE:-${4:?usage: update-nix-index.sh <model_dir> <sha256sum_bin> <jq_bin> <lockfile>}}"

_uni_platform="$(uname -m)-$(uname -s | tr '[:upper:]' '[:lower:]')"
case "$_uni_platform" in
aarch64-darwin | x86_64-linux) ;;
*)
  say -l nix-index "no pinned nix-index database for $_uni_platform; skipping"
  exit 0
  ;;
esac

# shellcheck disable=SC2016 # reason: jq program is a literal string # check-suppress:suppression_doc: the jq program is a literal string
_uni_url="$("$_uni_jq_bin" -r --arg p "$_uni_platform" '.["nix-index-database"][$p].url // empty' "$_uni_lockfile")"
# shellcheck disable=SC2016 # reason: jq program is a literal string # check-suppress:suppression_doc: the jq program is a literal string
_uni_hash_sri="$("$_uni_jq_bin" -r --arg p "$_uni_platform" '.["nix-index-database"][$p].hash // empty' "$_uni_lockfile")"
if [ -z "$_uni_url" ] || [ -z "$_uni_hash_sri" ]; then
  die -l nix-index "lockfile missing nix-index-database entry for $_uni_platform"
fi

_uni_want="$(printf '%s' "${_uni_hash_sri#sha256-}" | base64 -d | od -An -v -tx1 | tr -d ' \n')"
_uni_db_file="$_uni_model_dir/files"

mkdir -p "$_uni_model_dir"

if [ -f "$_uni_db_file" ]; then
  _uni_got="$("$_uni_sha256sum_bin" "$_uni_db_file" | cut -d' ' -f1)"
  if [ "$_uni_got" = "$_uni_want" ]; then
    say -l nix-index "database already current"
    exit 0
  fi
fi

_uni_tmp="$(mktemp "${TMPDIR:-/tmp}/nix-index.XXXXXX")"
trap 'rm -f "$_uni_tmp"' EXIT

say -l nix-index "downloading pinned nix-index database for $_uni_platform"
curl -fsSL "$_uni_url" -o "$_uni_tmp"
_uni_got="$("$_uni_sha256sum_bin" "$_uni_tmp" | cut -d' ' -f1)"
if [ "$_uni_got" != "$_uni_want" ]; then
  die -l nix-index "downloaded nix-index database hash mismatch for $_uni_platform"
fi

install -m 644 "$_uni_tmp" "$_uni_db_file"
rm -f "$_uni_tmp"
trap - EXIT
nuc_done -l nix-index "database refreshed"
