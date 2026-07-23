#!/usr/bin/env bash
# Nautilus right-click script for PDF optimization.
# MIME guard: only process application/pdf files.
# Preset name provided as optional first positional arg.
set -eu

preset="${1:-default}"
shift 2>/dev/null || true

pdfs=()
for f in "$@"; do
  case "$(file --mime-type -b "$f")" in
    application/pdf) pdfs+=("$f") ;;
  esac
done
if [ ${#pdfs[@]} -gt 0 ]; then
  exec nucleus-gs-pdf-opt --preset "$preset" "${pdfs[@]}"
fi
