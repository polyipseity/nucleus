# Shared Ghostscript PDF optimization logic with backup/restore.
# Usage: gs_pdf_opt [--preset <name>] <file>...
#
# For each file, renames original → .bak, runs gs optimization to the original
# path, removes .bak on success or restores it on failure.

gs_pdf_opt() {
  local preset="default"
  local files=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --preset)
        preset="$2"
        shift 2
        ;;
      --preset=*)
        preset="${1#*=}"
        shift
        ;;
      -*)
        echo "Unknown option: $1" >&2
        return 1
        ;;
      *)
        files+=("$1")
        shift
        ;;
    esac
  done

  if [[ ${#files[@]} -eq 0 ]]; then
    echo "Usage: gs_pdf_opt [--preset <name>] <file>..." >&2
    return 1
  fi

  case "$preset" in
    default|ebook|prepress|printer|screen) ;;
    *)
      echo "Unknown preset: $preset (valid: default, ebook, prepress, printer, screen)" >&2
      return 1
      ;;
  esac

  local gs_cmd
  gs_cmd="$(command -v gs)" || {
    echo "Error: gs not found in PATH" >&2
    return 1
  }

  local f bak
  for f in "${files[@]}"; do
    if [[ ! -f "$f" ]]; then
      echo "Skipping non-file: $f" >&2
      continue
    fi

    bak="${f}.bak"
    if [[ -e "$bak" ]]; then
      echo "Error: backup already exists, refusing to overwrite: $bak" >&2
      return 1
    fi

    mv "$f" "$bak"
    if "$gs_cmd" -sDEVICE=pdfwrite -dCompatibilityLevel=2.0 \
      "-dPDFSETTINGS=/$preset" -dNOPAUSE -dQUIET -dBATCH \
      -sOutputFile="$f" "$bak"; then
      rm -f "$bak"
      echo "Optimized: $f (preset: $preset)"
    else
      mv "$bak" "$f"
      echo "Error: optimization failed, restored original: $f" >&2
      return 1
    fi
  done
}
