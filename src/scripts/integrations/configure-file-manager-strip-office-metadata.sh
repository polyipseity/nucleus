#!/usr/bin/env bash
# Nautilus right-click script for stripping Office metadata.
# MIME guard: only process Office document MIME types.
set -eu

officemime=(
  'application/vnd.openxmlformats-officedocument.wordprocessingml.document'
  'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'
  'application/vnd.openxmlformats-officedocument.presentationml.presentation'
  'application/msword'
  'application/vnd.ms-excel'
  'application/vnd.ms-powerpoint'
)
files=()
for f in "$@"; do
  mime="$(file --mime-type -b "$f")"
  for m in "${officemime[@]}"; do
    if [ "$mime" = "$m" ]; then
      files+=("$f")
      break
    fi
  done
done
if [ ${#files[@]} -gt 0 ]; then
  exec nucleus-utils strip-office-metadata "${files[@]}"
fi
