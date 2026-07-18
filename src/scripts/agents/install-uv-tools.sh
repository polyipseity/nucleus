# Managed uv tool convergence (install + zap).
# Consumes __UV_BIN__, __GAWK_BIN__, __GREP_BIN__, __JQ_BIN__,
# and __DESIRED_UV_TOOLS_JSON__ at activation time.
# Expects the symlink hardening lib (symlink-hardening-lib.sh) to be sourced
# before this script runs.
set -eu

_iut_uv_bin='__UV_BIN__'
_iut_gawk_bin='__GAWK_BIN__'
_iut_grep_bin='__GREP_BIN__'
_iut_jq_bin='__JQ_BIN__'

# Desired tools as JSON object: {"tool_name": "python_version_or_null", ...}
# Read into a temp file in "tool python_version" format.
_iut_desired="$(mktemp)"
printf '%s\n' '__DESIRED_UV_TOOLS_JSON__' | "$_iut_jq_bin" -r 'to_entries[] | "\(.key) \(.value // "")' > "$_iut_desired"

# Build name-only list for comparison (strip version column).
_iut_desired_names="$(mktemp)"
"$_iut_gawk_bin" '{print $1}' "$_iut_desired" > "$_iut_desired_names"

# Install required Python versions before attempting tool installs.
# Stderr suppressed: uv emits a cosmetic "Failed to patch install name"
# warning on macOS 15+ when installing older CPython that does not affect
# functionality.  Real failures surface at tool-install time below.
while IFS=' ' read -r _iut_tool _iut_python; do
  [ -z "$_iut_tool" ] && continue
  # undoc-supp: uv python install may fail if the Python version is already installed or unavailable on this platform; that's fine — a real failure surfaces at tool-install time.
  [ -n "$_iut_python" ] && "$_iut_uv_bin" python install "$_iut_python" 2>/dev/null || true
done < "$_iut_desired"

# Get actually installed uv tools from `uv tool list` (zap-style: remove
# any installed tool absent from the desired list, regardless of prior
# managed state).  Parse only lines that match the documented
# "name vX.Y.Z" shape so separator/header lines (for example "-")
# cannot be misparsed as package names.
_iut_installed="$(mktemp)"
# undoc-supp: uv tool list may fail if no tool environment is initialised yet; treating the installed set as empty is correct — nothing to remove.
"$_iut_uv_bin" tool list 2>/dev/null | "$_iut_gawk_bin" '/^[A-Za-z0-9][A-Za-z0-9._-]*[[:space:]]+v[0-9]/{print $1}' > "$_iut_installed" || true

# Tools installed but not desired: zap-style removal.
_iut_to_remove="$(mktemp)"
while IFS= read -r _iut_tool; do
  [ -z "$_iut_tool" ] && continue
  if ! grep -qxF "$_iut_tool" "$_iut_desired_names"; then
    printf '%s\n' "$_iut_tool" >> "$_iut_to_remove"
  fi
done < "$_iut_installed"

# Desired tools not yet installed according to `uv tool list`.
_iut_to_install="$(mktemp)"
while IFS= read -r _iut_tool; do
  [ -z "$_iut_tool" ] && continue
  if ! grep -qxF "$_iut_tool" "$_iut_installed"; then
    printf '%s\n' "$_iut_tool" >> "$_iut_to_install"
  fi
done < "$_iut_desired_names"

# Prune tools removed from the desired list.
while IFS= read -r _iut_tool; do
  [ -z "$_iut_tool" ] && continue
  if ! printf '%s' "$_iut_tool" | "$_iut_grep_bin" -Eq '^[A-Za-z0-9][A-Za-z0-9._-]*$'; then
    echo "uv: skipping invalid uninstall token '$_iut_tool'"
    continue
  fi
  echo "uv: uninstalling removed tool '$_iut_tool'"
  "$_iut_uv_bin" tool uninstall "$_iut_tool"
done < "$_iut_to_remove"

# Install additions.
while IFS= read -r _iut_tool; do
  [ -z "$_iut_tool" ] && continue
  if ! printf '%s' "$_iut_tool" | "$_iut_grep_bin" -Eq '^[A-Za-z0-9][A-Za-z0-9._-]*$'; then
    echo "uv: skipping invalid install token '$_iut_tool'"
    continue
  fi

  # Look up the Python version for this tool from the desired list.
  _iut_python="$("$_iut_gawk_bin" -v tool="$_iut_tool" '$1 == tool { print $2; exit }' "$_iut_desired")"

  if [ -n "$_iut_python" ]; then
    echo "uv: installing tool '$_iut_tool' with Python $_iut_python"
    "$_iut_uv_bin" tool install --no-build --python "$_iut_python" "$_iut_tool"
  else
    echo "uv: installing tool '$_iut_tool'"
    "$_iut_uv_bin" tool install --no-build "$_iut_tool"
  fi
done < "$_iut_to_install"

if [ ! -s "$_iut_to_install" ] && [ ! -s "$_iut_to_remove" ]; then
  echo "uv: all managed tools already converged — skipping"
fi

rm -f "$_iut_desired" "$_iut_desired_names" "$_iut_installed" "$_iut_to_remove" "$_iut_to_install"
