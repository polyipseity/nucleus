# Shared shell body for displayHostManualInstructions activation hook.
# Parameterized by OS label so macos.nix and linux.nix can reuse the
# same logic without duplication.
{ hostManualFile }: osLabel: ''
  _manual_path='${hostManualFile}'
  _repo_root_file="$HOME/.config/nucleus/repo-root"
  _resolved_manual_path="$_manual_path"

  case "$_manual_path" in
    /*) ;;
    *)
      if [ -n "''${NUCLEUS_REPO:-}" ]; then
        _resolved_manual_path="$NUCLEUS_REPO/$_manual_path"
      elif [ -f "$_repo_root_file" ]; then
        _resolved_manual_path="$(cat "$_repo_root_file")/$_manual_path"
      fi
      ;;
  esac

  if [ ! -f "$_resolved_manual_path" ]; then
    echo "${osLabel}: host manual not found at $_resolved_manual_path (configured: $_manual_path)." >&2
    exit 1
  fi

  echo "--- MANUAL SETUP (one-time, required) ---" >&2
  /bin/cat "$_resolved_manual_path" >&2
  echo "-------------------------------------------" >&2
''
