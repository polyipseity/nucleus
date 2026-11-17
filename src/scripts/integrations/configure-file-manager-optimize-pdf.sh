#!/usr/bin/env bash
# Nautilus right-click script for PDF optimization.
# MIME guard: only process application/pdf files.
# Preset name provided via PDF_OPT_PRESET env var or first positional arg.
set -eu

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd -P)"
# shellcheck source=../lib/bash-guard.sh
. "$SCRIPT_DIR/../lib/bash-guard.sh"
bash_guard_require 5 1 configure-file-manager-optimize-pdf

preset="${PDF_OPT_PRESET:-${1:-default}}"
shift 2>/dev/null || true # check-suppress:suppression_doc: expected failure when fewer args than shift count

pdfs=()
for f in "$@"; do
  case "$(file --mime-type -b "$f")" in
  application/pdf) pdfs+=("$f") ;;
  esac
done
if [ ${#pdfs[@]} -gt 0 ]; then
  exec nucleus-utils optimize-pdf --preset "$preset" "${pdfs[@]}"
fi
