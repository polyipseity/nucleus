#!/usr/bin/env bash
# Verifies harness-clipboard selects a backend, forwards stdin verbatim, and
# fails loudly when no backend is usable.
set -euo pipefail
SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
REPO_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/../.." && pwd -P)"
. "$SCRIPT_DIR/test-lib.sh"
init_test_state

stub_dir="$HOME/bin"
mkdir -p "$stub_dir"
cat >"$stub_dir/pbcopy" <<'STUB'
#!/usr/bin/env bash
cat > "$STUB_CAPTURE"
STUB
chmod +x "$stub_dir/pbcopy"

capture="$HOME/captured.txt"
export STUB_CAPTURE="$capture"
export NUCLEUS_CLIPBOARD_BACKEND="pbcopy"

printf 'line one\nline two with  spaces\n' |
  PATH="$stub_dir:$PATH" bash "$REPO_ROOT/src/scripts/notify/harness-clipboard.sh"

if [ -f "$capture" ] && [ "$(cat "$capture")" = "$(printf 'line one\nline two with  spaces\n')" ]; then
  assert_pass "pbcopy backend receives stdin verbatim" ""
else
  assert_fail "pbcopy backend receives stdin verbatim" "captured: $(cat "$capture" 2>/dev/null || printf 'nothing')"
fi

if printf 'x\n' | PATH="$stub_dir" NUCLEUS_CLIPBOARD_BACKEND=none bash "$REPO_ROOT/src/scripts/notify/harness-clipboard.sh" 2>/dev/null; then # check-suppress:suppression_doc: exit status is asserted below
  assert_fail "an unknown backend fails loudly" "exit status was 0"
else
  assert_pass "an unknown backend fails loudly" ""
fi

finish_tests
