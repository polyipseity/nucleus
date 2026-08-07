#!/usr/bin/env bash
# ---- macos-remove-command-line-tools -----------------------------------------
# Remove Apple's Command Line Tools tree and pkgutil receipts on each apply.
#
# WHY: nucleus provisions a Nix-only developer toolchain (apple-sdk-enhanced +
# LLVM via absolute CC/CXX/LD). Apple CLT is not used. Orphaned or installed
# CLT receipts still make Software Update offer CLT updates (~1 GB each). This
# script pairs with xcode-select --switch in activation.nix, which runs
# immediately after removal.
#
# Positional arguments:
#   $1 — path to verbose log file (e.g. systemLogDir/command-line-tools.log)
#
# Scope: /Library/Developer/CommandLineTools only. Does not touch Xcode.app or
# other /Library/Developer paths. Does not call softwareupdate.
set -eu

CLT_DIR="/Library/Developer/CommandLineTools"

LOG_FILE="${1:-/Users/Shared/nucleus/logs/command-line-tools.log}"
/bin/mkdir -p "$(dirname "$LOG_FILE")"

_log() {
  printf '[%s] command-line-tools: %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*" >> "$LOG_FILE"
}

_changed=0

if [ -d "$CLT_DIR" ]; then
  if /bin/rm -rf "$CLT_DIR"; then
    _log "removed $CLT_DIR"
    _changed=1
  else
    echo "command-line-tools: failed to remove $CLT_DIR." >&2
  fi
fi

for pkg in $(/usr/sbin/pkgutil --pkgs); do
  case "$pkg" in
    *CLTools* | *CommandLineTools*)
      # check-suppress:suppression_doc: forget is a no-op when receipt already absent; stderr only reports expected missing receipt
      if /usr/sbin/pkgutil --forget "$pkg" >/dev/null 2>&1; then
        _log "forgot receipt $pkg"
        _changed=1
      else
        echo "command-line-tools: failed to forget $pkg." >&2
      fi
      ;;
  esac
done

if [ "$_changed" -eq 0 ]; then
  _log "already absent"
  echo "command-line-tools: already absent." >&2
fi
