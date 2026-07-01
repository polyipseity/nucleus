#!/usr/bin/env bash
# nucleus-gs-pdf-opt: Optimize PDF files with Ghostscript (backup/restore).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

. "$REPO_ROOT/src/scripts/gs-pdf-opt.sh"

main() {
  if [[ $# -eq 0 ]] || [[ "$1" == "-h" ]] || [[ "$1" == "--help" ]]; then
    echo "Usage: $(basename "$0") [--preset <name>] <file>..."
    echo ""
    echo "Optimize PDF files using Ghostscript. Creates .bak backup before processing."
    echo ""
    echo "Presets (default: default):"
    echo "  default   - high quality"
    echo "  ebook     - medium quality (good for e-readers)"
    echo "  prepress  - high quality (preserves color, suitable for printing)"
    echo "  printer   - medium quality for printing"
    echo "  screen    - low quality (smallest file)"
    echo ""
    echo "If a .bak file already exists for any input, the command refuses and exits."
    echo "On failure, the original file is restored from backup."
    exit 0
  fi

  gs_pdf_opt "$@"
}

main "$@"
