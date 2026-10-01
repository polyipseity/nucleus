# shellcheck shell=bash
# Supervisor backend for launchd (macOS), one half of the uniform supervisor_*
# contract consumed by service-watchdog.sh. A target is "<domain>/<uid>/<label>"
# (gui) or "<domain>/<label>" (system). The sudo prefix follows from the
# domain, so every backend takes the same arguments in the same order.

[ -n "${_NUCLEUS_SUPERVISOR_LAUNCHD_SOURCED-}" ] && return
_NUCLEUS_SUPERVISOR_LAUNCHD_SOURCED=1

_SUPERVISOR_LAUNCHD_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib.sh
[ -n "${_NUCLEUS_LIB_SOURCED-}" ] || . "$_SUPERVISOR_LAUNCHD_DIR/lib.sh"
# WHY: load and unload go through the shared macOS helpers, which carry the
#   macOS 26+ asynchronous-unload wait and the "Bootstrap failed: 5" retry. A raw
#   `launchctl bootstrap`/`bootout` pair reintroduces the race they close, where
#   a bootout landing after a bootstrap leaves the job unloaded.
# shellcheck source=macos-launch-services.sh
. "$_SUPERVISOR_LAUNCHD_DIR/macos-launch-services.sh"

_launchd_label() {
  printf '%s' "${1##*/}"
}

_launchd_domain() {
  printf '%s' "${1%%/*}"
}

# Empty for the system domain, which launchctl addresses without a uid.
_launchd_uid() {
  local rest="${1#*/}"
  case "$rest" in
  */*) printf '%s' "${rest%%/*}" ;;
  *) printf '' ;;
  esac
}

_launchd_sudo_prefix() {
  [ "$(_launchd_domain "$1")" = "system" ] && printf 'sudo'
}

# The target with its label stripped ("gui/501/local.foo" -> "gui/501"), which is
# what `launchctl print-disabled` addresses.
_launchd_domain_target() {
  printf '%s' "${1%/*}"
}

# Prints enabled | disabled | unknown.
# WHY: `launchctl disable`/`enable` (scripts/svc.sh) writes the override DB and
#   never a plist `Disabled` key, which nothing in the repository writes. Reading
#   the key made the predicate degenerate to "the plist exists" and left Rule 1's
#   user-disabled branch unreachable on macOS. The DB lists every overridden label
#   as `"<label>" => disabled|enabled`, so an absent label means not disabled,
#   which is the booted-out state Rule 4 must still revive.
_launchd_override_state() {
  local target="$1" label domain_target overrides
  label="$(_launchd_label "$target")"
  domain_target="$(_launchd_domain_target "$target")"
  # A target without a label has no domain to query.
  if [ -z "$label" ] || [ -z "$domain_target" ] || [ "$domain_target" = "$target" ]; then
    printf 'unknown'
    return 0
  fi
  # check-suppress:suppression_doc: an unreadable override DB is reported as unknown, and supervisor_enabled fails closed on unknown
  overrides="$(launchctl print-disabled "$domain_target" 2>/dev/null || true)"
  # An unreadable reply is unknown, not enabled, so the caller fails closed.
  case "$overrides" in
  *"disabled services"*) ;;
  *)
    printf 'unknown'
    return 0
    ;;
  esac
  if printf '%s\n' "$overrides" | grep -Fq -- "\"$label\" => disabled"; then
    printf 'disabled'
    return 0
  fi
  printf 'enabled'
}

# Args: $1 target, $2 declared path (optional). A plist filename always equals
# the job label, so a declared path contributes only its directory (per-user
# LaunchAgents vs system LaunchDaemons).
supervisor_unit_path() {
  local target="$1" declared="${2:-}" label domain resolved
  label="$(_launchd_label "$target")"
  domain="$(_launchd_domain "$target")"
  if [ -z "$declared" ]; then
    case "$domain" in
    gui) printf '%s/Library/LaunchAgents/%s.plist' "$HOME" "$label" ;;
    system) printf '/Library/LaunchDaemons/%s.plist' "$label" ;;
    *) printf '' ;;
    esac
    return 0
  fi
  resolved="$(supervisor_resolve_unit_path "$declared" "$label")"
  printf '%s/%s.plist' "${resolved%/*}" "$label"
}

# 0 when the job exists and the user has not disabled it.
# Args: $1 target, $2 declared unit path, $3 scope (accepted for contract
# symmetry; launchd ignores it).
# WHY: the contract reports "exists and is allowed to start", so ABSENT counts as
#   not enabled. That lets the watchdog report a declared-but-uninstalled job as
#   not loaded instead of starting a plist that does not exist. Loaded-ness is
#   deliberately not part of it: an unloaded job is the state Rule 4 repairs. An
#   UNKNOWN override state fails closed, so an unreadable disable is never
#   overridden into a start-and-warn attempt on every tick.
supervisor_enabled() {
  local target="$1" declared="${2:-}" plist
  # WHY the declared path: start and repair consume it too, so a job whose plist
  #   sits at a non-default path would read as ABSENT here, and Rule 1 skips an
  #   absent job forever: never revived, never repaired.
  plist="$(supervisor_unit_path "$target" "$declared")"
  [ -n "$plist" ] && [ -f "$plist" ] || return 1
  case "$(_launchd_override_state "$target")" in
  enabled) return 0 ;;
  *) return 1 ;;
  esac
}

# Args: $1 output of `launchctl print`.
supervisor_live() {
  local print_out="$1"
  case "$print_out" in
  *"state = running"*) return 0 ;;
  esac
  return 1
}

# The job's run token, a value that changes on every new run. launchd reports a
# monotonic run count; the watchdog only compares for inequality.
# Args: $1 target, $2 scope (accepted for contract symmetry; launchd ignores it).
supervisor_generation() {
  local target="$1" runs
  # check-suppress:suppression_doc: an unloaded job has no counter; zero restarts is the correct reading
  runs="$(launchctl print "$target" 2>/dev/null | awk '/runs =/{print $3; exit}')"
  printf '%s' "${runs:-0}"
}

# Last exit status for the job, as an integer.
# launchctl writes it as "last exit code = 78: EX_CONFIG", "last exit code =
# (never exited)", or a bare number, so the status is the leading integer.
# WHY: the remainder is not a JSON literal, so a bare `(never` or `78:` makes the
#   health write fail and, under `set -e`, kills the tick. It also made Rule 5's
#   EX_CONFIG repair unreachable, since "78:" never equals "78".
# Args: $1 target, $2 scope (accepted for contract symmetry; launchd ignores it).
supervisor_last_exit() {
  local target="$1" code
  # check-suppress:suppression_doc: a job that never exited has no status; zero is the correct reading
  code="$(launchctl print "$target" 2>/dev/null |
    awk '/last exit code/ { sub(/^[^=]*= */, ""); if (match($0, /^-?[0-9]+/)) print substr($0, 1, RLENGTH); exit }')"
  printf '%s' "${code:-0}"
}

# Args: $1 target, $2 declared unit path (optional), $3 scope (unused: the sudo
#       prefix follows from the target's domain). Returns 0 when the job is
#       loaded afterwards, 1 otherwise with launchctl's own message on stdout.
supervisor_start() {
  local target="$1" declared="${2:-}" plist bootstrap_domain sudo_prefix
  plist="$(supervisor_unit_path "$target" "$declared")"
  [ -n "$plist" ] || return 1
  bootstrap_domain="$(launchctl_bootstrap_domain "$(_launchd_domain "$target")" "$(_launchd_uid "$target")")"
  sudo_prefix="$(_launchd_sudo_prefix "$target")"
  launchctl_bootstrap_plist "$bootstrap_domain" "$plist" "$target" "$sudo_prefix"
}

# Bootout the job, waiting out the macOS 26+ asynchronous unload so a bootstrap
# issued next cannot race it.
# Args: $1 target, $2 scope (unused). Returns 0 when the job is no longer loaded,
# including when it never was, 1 when it survives the bounded wait.
supervisor_stop() {
  local target="$1" sudo_prefix
  sudo_prefix="$(_launchd_sudo_prefix "$target")"
  launchctl_bootout_wait "$target" "$sudo_prefix"
}

# Args: $1 target, $2 declared unit path (optional), $3 scope (unused).
# Returns 0 when the job is loaded again. A repair that cannot unload repaired
# nothing, so the reload is not attempted on top of a loaded job.
supervisor_repair() {
  local target="$1" declared="${2:-}"
  if ! supervisor_stop "$target"; then
    return 1
  fi
  sleep 1
  supervisor_start "$target" "$declared"
}

supervisor_kind() {
  printf 'launchd'
}
