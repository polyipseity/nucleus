# shellcheck shell=bash
# Intersection-based Nix profile generation expiry (age AND count).
#
# Source after lib.sh. A generation is kept only when it is among the newest
# `keep` generations AND newer than `age`. Implemented as sequential nix-env
# calls: delete older than age, then delete all but newest keep.

resolve_system_profile() {
  for _epg_profile in /nix/var/nix/profiles/system /run/current-system; do
    if [ -e "$_epg_profile" ]; then
      printf '%s\n' "$_epg_profile"
      return 0
    fi
  done
  return 1
}

resolve_hm_profile() {
  _epg_home="${1:-$HOME}"
  _epg_user="$(id -un 2>/dev/null || printf '%s' "${USER:-}")"
  for _epg_profile in \
    "$_epg_home/.local/state/nix/profiles/home-manager" \
    "/nix/var/nix/profiles/per-user/${_epg_user}/home-manager"; do
    if [ -e "$_epg_profile" ]; then
      printf '%s\n' "$_epg_profile"
      return 0
    fi
  done
  return 1
}

_expire_profile_generations_run_nix_env() {
  _epg_profile="$1"
  shift
  if [ "${NUCLEUS_GC_PROFILE_SUDO:-false}" = true ]; then
    sudo nix-env -p "$_epg_profile" "$@"
  else
    nix-env -p "$_epg_profile" "$@"
  fi
}

expire_profile_generations_intersection() {
  _epg_profile="$1"
  _epg_keep="$2"
  _epg_age="$3"
  _epg_dry_run="$4"

  if [ ! -e "$_epg_profile" ]; then
    say "profile '$_epg_profile' not found; skipping generation expiry"
    return 0
  fi

  if ! command -v nix-env >/dev/null 2>&1; then
    say "nix-env unavailable; skipping generation expiry for '$_epg_profile'"
    return 0
  fi

  if [ "$_epg_dry_run" = true ]; then
    _epg_sudo_hint=""
    if [ "${NUCLEUS_GC_PROFILE_SUDO:-false}" = true ]; then
      _epg_sudo_hint=" (via sudo)"
    fi
    dry_run "would expire generations on '$_epg_profile' (keep newest $_epg_keep AND newer than $_epg_age)$_epg_sudo_hint"
    return 0
  fi

  _expire_profile_generations_run_nix_env "$_epg_profile" --delete-generations "$_epg_age"
  _expire_profile_generations_run_nix_env "$_epg_profile" --delete-generations "+${_epg_keep}"
}
