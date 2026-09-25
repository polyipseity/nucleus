# shellcheck shell=bash
# Supervisor backend for launchd (macOS).
# Implements the uniform supervisor_* contract consumed by service-watchdog.sh.
#
# Contract (identical arity on every backend):
#   supervisor_unit_path <target> [declared path]      — resolve the plist path
#   supervisor_enabled   <target> [unit path] [scope]  — 0 when it exists and is not disabled
#   supervisor_live      <probe output>                — 0 when the job is running
#   supervisor_generation <target> [scope]             — run token, changes per run
#   supervisor_last_exit <target> [scope]              — last exit status
#   supervisor_start     <target> [unit path] [scope]  — load and start
#   supervisor_stop      <target> [scope]              — unload
#   supervisor_repair    <target> [unit path] [scope]  — unload + reload a wedged job
#   supervisor_kind                                    — backend identifier
#
# A target is "<domain>/<uid>/<label>" (gui) or "<domain>/<label>" (system).
# The sudo prefix follows from the domain, so scope needs no separate plumbing.
#
# Usage:
#   . "$SCRIPT_DIR/../lib/supervisor-launchd.sh"

[ -n "${_NUCLEUS_SUPERVISOR_LAUNCHD_SOURCED-}" ] && return
_NUCLEUS_SUPERVISOR_LAUNCHD_SOURCED=1

_SUPERVISOR_LAUNCHD_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib.sh
[ -n "${_NUCLEUS_LIB_SOURCED-}" ] || . "$_SUPERVISOR_LAUNCHD_DIR/lib.sh"
# WHY: load and unload must go through the shared macOS helpers. They carry the
#   macOS 26+ asynchronous-unload wait and the "Bootstrap failed: 5" retry; a raw
#   `launchctl bootstrap`/`bootout` pair reintroduces the race they exist to
#   close, where a bootout landing after a bootstrap leaves the job unloaded.
# shellcheck source=macos-launch-services.sh
. "$_SUPERVISOR_LAUNCHD_DIR/macos-launch-services.sh"

# _launchd_label — the job label, the last component of a target.
_launchd_label() {
  printf '%s' "${1##*/}"
}

# _launchd_domain — the launchd domain, the first component of a target.
_launchd_domain() {
  printf '%s' "${1%%/*}"
}

# _launchd_uid — the uid of a gui/user-domain target; empty for the system
# domain, which launchctl addresses without one.
_launchd_uid() {
  local rest="${1#*/}"
  case "$rest" in
  */*) printf '%s' "${rest%%/*}" ;;
  *) printf '' ;;
  esac
}

# _launchd_sudo_prefix — sudo when the target lives in the system domain.
_launchd_sudo_prefix() {
  [ "$(_launchd_domain "$1")" = "system" ] && printf 'sudo'
}

# _launchd_domain_target — the service target's DOMAIN, which is what
# `launchctl print-disabled` addresses: the target with its label stripped
# ("gui/501/local.foo" -> "gui/501", "system/local.foo" -> "system").
_launchd_domain_target() {
  printf '%s' "${1%/*}"
}

# _launchd_override_state — the job's state in the launchctl OVERRIDE DB.
# Args: $1 — target.
# Prints: enabled | disabled | unknown
# WHY: `launchctl disable`/`enable` is the only disable mechanism nucleus uses
#   (scripts/svc.sh), and it writes the override DB — never the plist. Nothing
#   in the repository writes a plist `Disabled` key, so reading that key made the
#   predicate degenerate to "the plist file exists" and left Rule 1's
#   user-disabled branch unreachable on macOS. The DB lists every overridden
#   label as `"<label>" => disabled|enabled`, so an absent label means "not
#   disabled", which is exactly the booted-out state Rule 4 must still revive.
_launchd_override_state() {
  local target="$1" label domain_target overrides
  label="$(_launchd_label "$target")"
  domain_target="$(_launchd_domain_target "$target")"
  # A target without a label has no domain to query; report that as unknown
  # rather than guessing a domain.
  if [ -z "$label" ] || [ -z "$domain_target" ] || [ "$domain_target" = "$target" ]; then
    printf 'unknown'
    return 0
  fi
  # check-suppress:suppression_doc: an unreadable override DB is reported as unknown, and supervisor_enabled fails closed on unknown
  overrides="$(launchctl print-disabled "$domain_target" 2>/dev/null || true)"
  # An empty or unrecognisable reply is not a licence to treat the job as
  # enabled: report it as unknown so the caller fails closed.
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

# supervisor_unit_path — resolve the plist path for a target.
# Args: $1 — target; $2 — declared path (optional).
# A plist filename always equals the job label, so a declared path contributes
# its directory (per-user LaunchAgents vs system LaunchDaemons).
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
  # Only the declared directory is used: a plist filename always equals its label.
  resolved="$(supervisor_resolve_unit_path "$declared" "$label")"
  printf '%s/%s.plist' "${resolved%/*}" "$label"
}

# supervisor_enabled — 0 when the job exists and the user has not disabled it.
# WHY: this is the shared supervisor contract, and the Windows adapters spell it
#   out — Supervisor-Enabled reports "exists and is allowed to start". Rule 1
#   therefore covers ABSENT as well as disabled, which is what lets the watchdog
#   report a declared-but-uninstalled job as not-loaded instead of trying to
#   start a plist that does not exist. Loaded-ness is deliberately NOT part of
#   this: an unloaded job is exactly the state revival (Rule 4) exists to repair,
#   and a job booted out while its plist remained is the case Rule 4 exists for.
# The disable half is read from the override DB (see _launchd_override_state),
# and an UNKNOWN state fails CLOSED: a disable this function cannot read must not
# be overridden into a start-and-warn attempt on every tick.
# Args: $1 — target; $2 — declared unit path; $3 — scope (accepted for contract
#       symmetry; launchd ignores it — the sudo prefix follows from the domain).
supervisor_enabled() {
  local target="$1" declared="${2:-}" plist
  # WHY the declared path: start and repair already consume it, so a job whose
  #   plist sits at a non-default path would otherwise be reported ABSENT here,
  #   and Rule 1 skips an absent job forever — never revived, never repaired.
  #   "One declared policy, two algorithms" is what made that possible.
  plist="$(supervisor_unit_path "$target" "$declared")"
  [ -n "$plist" ] && [ -f "$plist" ] || return 1
  case "$(_launchd_override_state "$target")" in
  enabled) return 0 ;;
  *) return 1 ;;
  esac
}

# supervisor_live — is the job currently running?
# Args: $1 — the output of `launchctl print`.
supervisor_live() {
  local print_out="$1"
  case "$print_out" in
  *"state = running"*) return 0 ;;
  esac
  return 1
}

# supervisor_generation — the job's run token: a value that changes whenever the
# job starts a new run.  launchd reports it as a monotonic run count, so the
# watchdog sees a change exactly when the job was restarted.
# WHY: not named for a count — on Windows the same contract is fed process
#   identity or a run timestamp, where no count exists.  The watchdog compares
#   only for inequality, so one name covers both.
# Args: $1 — target; $2 — scope (accepted for contract symmetry; launchd ignores it).
supervisor_generation() {
  local target="$1" runs
  # check-suppress:suppression_doc: an unloaded job has no counter; zero restarts is the correct reading
  runs="$(launchctl print "$target" 2>/dev/null | awk '/runs =/{print $3; exit}')"
  printf '%s' "${runs:-0}"
}

# supervisor_last_exit — last exit status for the job, as an integer.
# launchctl writes the status as "last exit code = 78: EX_CONFIG",
# "last exit code = (never exited)", and a bare number otherwise, so the status
# is the leading integer of the value — never the whole value.
# WHY: reading the remainder hands jq a bare word like `(never` or `78:`, which
#   is not a JSON literal: the health write fails, and under `set -e` that aborts
#   the whole tick, so the watchdog died on the first live job that had never
#   exited.  It also made Rule 5's EX_CONFIG repair unreachable, since "78:"
#   never equals "78".
# Args: $1 — target; $2 — scope (accepted for contract symmetry; launchd ignores it).
supervisor_last_exit() {
  local target="$1" code
  # check-suppress:suppression_doc: a job that never exited has no status; zero is the correct reading
  code="$(launchctl print "$target" 2>/dev/null |
    awk '/last exit code/ { sub(/^[^=]*= */, ""); if (match($0, /^-?[0-9]+/)) print substr($0, 1, RLENGTH); exit }')"
  printf '%s' "${code:-0}"
}

# supervisor_start — bootstrap (load) the job.
# Args: $1 — target; $2 — declared unit path (optional); $3 — scope (unused: the
#       sudo prefix follows from the target's domain).
# Returns: 0 when the job is loaded afterwards; 1 otherwise, with launchctl's own
#          message on stdout so the caller can quote the reason.
supervisor_start() {
  local target="$1" declared="${2:-}" plist bootstrap_domain sudo_prefix
  plist="$(supervisor_unit_path "$target" "$declared")"
  [ -n "$plist" ] || return 1
  bootstrap_domain="$(launchctl_bootstrap_domain "$(_launchd_domain "$target")" "$(_launchd_uid "$target")")"
  sudo_prefix="$(_launchd_sudo_prefix "$target")"
  launchctl_bootstrap_plist "$bootstrap_domain" "$plist" "$target" "$sudo_prefix"
}

# supervisor_stop — bootout (unload) the job, waiting out the macOS 26+
# asynchronous unload so a bootstrap issued next cannot race it.
# Args: $1 — target; $2 — scope (unused: the sudo prefix follows from the target's domain).
# Returns: 0 when the job is no longer loaded (including when it never was), 1
#          when it is still loaded after the bounded wait.
supervisor_stop() {
  local target="$1" sudo_prefix
  sudo_prefix="$(_launchd_sudo_prefix "$target")"
  launchctl_bootout_wait "$target" "$sudo_prefix"
}

# supervisor_repair — bootout + bootstrap for a wedged job (EX_CONFIG 78).
# Args: $1 — target; $2 — declared unit path (optional); $3 — scope (unused).
# Returns: 0 when the job is loaded again; 1 when it could not be unloaded, or
#          could not be reloaded. A repair that cannot unload has repaired
#          nothing, so the reload is not attempted on top of a loaded job.
supervisor_repair() {
  local target="$1" declared="${2:-}"
  if ! supervisor_stop "$target"; then
    return 1
  fi
  sleep 1
  supervisor_start "$target" "$declared"
}

# supervisor_kind — the supervisor kind identifier.
supervisor_kind() {
  printf 'launchd'
}
