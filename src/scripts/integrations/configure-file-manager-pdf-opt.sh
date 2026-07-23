#!/usr/bin/env bash
# Nautilus right-click script for PDF optimization.
# MIME guard: only process application/pdf files.
# Preset name provided via PDF_OPT_PRESET env var or first positional arg.
set -eu

preset="${PDF_OPT_PRESET:-${1:-default}}"
shift 2>/dev/null || true # check-suppress:suppression_doc: expected failure when fewer args than shift count

pdfs=()
for f in "$@"; do
  case "$(file --mime-type -b "$f")" in
    application/pdf) pdfs+=("$f") ;;
  esac
done
if [ ${#pdfs[@]} -gt 0 ]; then
  exec nucleus-gs-pdf-opt --preset "$preset" "${pdfs[@]}"
fi
