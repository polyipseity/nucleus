#!/usr/bin/env bash
# Remove Apple's Command Line Tools install tree on each apply.
#
# WHY: nucleus provisions a Nix-only toolchain (apple-sdk-enhanced + LLVM via
# absolute CC/CXX/LD). CLT files go unused and cost ~1 GB. The pkgutil receipts
# on /Library/Apple/System are SIP-protected and stay, so Software Update may
# still offer a CLT install.
#
# Usage: macos-remove-command-line-tools <path to verbose log file>
# Scope is /Library/Developer/CommandLineTools only: no Xcode.app, no receipts,
# no other /Library/Developer path.
set -eu

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=../../../scripts/lib/lib.sh
. "$SCRIPT_DIR/../../../scripts/lib/lib.sh"

CLT_DIR="/Library/Developer/CommandLineTools"

LOG_FILE="${1:-/Library/Application Support/nucleus/logs/command-line-tools.log}"
/bin/mkdir -p "$(dirname "$LOG_FILE")"

_log() {
  printf '[%s] command-line-tools: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >>"$LOG_FILE"
}

if [ -d "$CLT_DIR" ]; then
  if /bin/rm -rf "$CLT_DIR"; then
    _log "removed $CLT_DIR"
    say -l command-line-tools "removed $CLT_DIR."
  else
    die -l command-line-tools "failed to remove $CLT_DIR."
  fi
else
  _log "install tree already absent"
  say -l command-line-tools "install tree already absent."
fi
