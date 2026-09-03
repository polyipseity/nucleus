#!/usr/bin/env bash
# LibreOffice XCU merge orchestration: applies managed metadata-stripping
# entries into registrymodifications.xcu on macOS and Linux.
#
# Windows uses an equivalent PowerShell module (Sync-LibreOfficeXcu.ps1).

set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"

_mlrx_python3_bin="$1"
_mlrx_xcu_file="$2"
shift 2
# Remaining args are "path|name|value" triples.

case "$(uname -s)" in
Darwin | Linux)
  mkdir -p "$(dirname "$_mlrx_xcu_file")"
  "$_mlrx_python3_bin" "$SCRIPT_DIR/merge-libreoffice-xcu.py" "$_mlrx_xcu_file" "$@"
  ;;
*)
  exit 0
  ;;
esac
