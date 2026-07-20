#!/usr/bin/env bash
# Nautilus right-click script for PDF optimization.
# MIME guard: only process application/pdf files.
# Variables below are substituted via Nix replaceStrings at build time.
set -eu

pdfs=()
for f in "$@"; do
  case "$(__FILE_BIN__ --mime-type -b "$f")" in
    application/pdf) pdfs+=("$f") ;;
  esac
done
if [ ${#pdfs[@]} -gt 0 ]; then
  exec nucleus-gs-pdf-opt --preset __GS_PDF_OPT_PRESET__ "${pdfs[@]}"
fi
