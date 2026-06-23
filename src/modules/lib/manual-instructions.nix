# Shared shell body for displayHostManualInstructions activation hook.
# Parameterized by OS label so macos.nix and linux.nix can reuse the
# same logic without duplication.
{ hostManualFile }: { osLabel, repoRoot }: ''
  _manual_path='${hostManualFile}'
  _resolved_manual_path="$_manual_path"

  case "$_manual_path" in
    /*) ;;
    *)
      _repo_root="${repoRoot}"
      if [ -z "$_repo_root" ] || [ ! -d "$_repo_root" ]; then
        _repo_root="''${NUCLEUS_REPO:?${osLabel}: NUCLEUS_REPO not set; run via apply.sh}"
      fi
      _resolved_manual_path="$_repo_root/$_manual_path"
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
