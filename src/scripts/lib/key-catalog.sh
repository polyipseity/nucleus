#!/usr/bin/env bash
# Shared key-catalog generation for Nix consumers (sops.nix, ai.nix).
#
# The AI key catalog (key-catalog.json) is generated from the decrypted
# system.yml so Nix modules can discover available AI API keys and their env
# var mappings at evaluation time.  Nix modules read it via
# `builtins.getEnv "NUCLEUS_CATALOG_PATH"`; an empty value makes
# `builtins.readFile ""` fail, so every nix invocation path (apply.sh, the
# check nix-flake-eval step, the test system-config-build step) must ensure the
# catalog exists first.  This lib is the single source of truth for that.

# Guard against re-sourcing.
[ -n "${_NUCLEUS_KEY_CATALOG_SOURCED-}" ] && return
_NUCLEUS_KEY_CATALOG_SOURCED=1

_self="${BASH_SOURCE[0]:-$0}"
_NUCLEUS_KC_LIB_DIR="$(CDPATH='' cd -- "$(dirname -- "$_self")" && pwd)"

# Defensively source lib.sh (say/warn/derive_repo_root) only if absent — callers
# (apply.sh, check-lib.sh, test-lib.sh) already source it, and re-sourcing would
# clobber their SCRIPT_DIR/REPO_ROOT.
if ! command -v derive_repo_root >/dev/null 2>&1; then
  # shellcheck source=lib.sh
  . "$_NUCLEUS_KC_LIB_DIR/lib.sh"
fi

# ensure_key_catalog
# Generate key-catalog.json (if missing) and export NUCLEUS_CATALOG_PATH.
# Idempotent: if the var is already set to an existing file, skip regeneration.
ensure_key_catalog() {
  if [ -n "${NUCLEUS_CATALOG_PATH:-}" ] && [ -f "$NUCLEUS_CATALOG_PATH" ]; then
    return 0
  fi

  local _gkm_repo_root="${REPO_ROOT:-$(derive_repo_root)}"
  local _gkm_yml="$_gkm_repo_root/src/secrets/system.yml"
  local _gkm_out="$NUCLEUS_USER_ROOT/key-catalog.json"
  mkdir -p "$NUCLEUS_USER_ROOT"

  if [ ! -f "$_gkm_yml" ]; then
    say -l key-catalog "system.yml not found; generating empty key catalog"
    # shellcheck disable=SC2016 # reason: $schema is a JSON key in the output, not a shell variable
    printf '%s' '{"$schema":"'"$_gkm_repo_root/src/modules/ai/key-catalog.schema.json"'","keys":[]}' >"$_gkm_out"
  elif ! _gkm_decrypted="$(sops -d --output-type json "$_gkm_yml" 2>/dev/null)"; then
    warn -l key-catalog "sops decryption failed; generating empty key catalog"
    # shellcheck disable=SC2016 # reason: $schema is a JSON key in the output, not a shell variable
    printf '%s' '{"$schema":"'"$_gkm_repo_root/src/modules/ai/key-catalog.schema.json"'","keys":[]}' >"$_gkm_out"
  else
    # Build catalog: extract ai_*_api_key entries with non-null values, derive
    # envVar from key name via convention: ai_<X>_api_key → <X>_API_KEY.
    # shellcheck disable=SC2016 # reason: jq filter uses $schema as a literal JSON key, not shell expansion
    printf '%s' "$_gkm_decrypted" | jq --arg repoRoot "$_gkm_repo_root" '
      [to_entries[]
        | select(.key | test("^ai_.+_api_key"))
        | select(.value != null)
        | .key as $k
        | ($k | sub("^ai_"; "") | sub("_api_key(_[0-9]+)?$"; "") | ascii_upcase) as $base
        | if ($k | test("_api_key_[0-9]+$"))
          then { name: $k, envVar: ($base + "_API_KEY_" + ($k | capture("_api_key_(?<i>[0-9]+)$").i)) }
          else { name: $k, envVar: ($base + "_API_KEY") }
          end
      ]
      | {"$schema": ($repoRoot + "/src/modules/ai/key-catalog.schema.json"), "keys": .}
    ' >"$_gkm_out"
    say -l key-catalog "wrote key-catalog.json with $(jq '.keys | length' "$_gkm_out") keys"
  fi

  NUCLEUS_CATALOG_PATH="$_gkm_out"
  export NUCLEUS_CATALOG_PATH
}
