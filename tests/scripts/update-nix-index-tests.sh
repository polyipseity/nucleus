#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
REPO_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/../.." && pwd -P)"
SCRIPT_UNDER_TEST="$REPO_ROOT/src/scripts/packages/update-nix-index.sh"

. "$SCRIPT_DIR/test-lib.sh"

require_command python3
require_command shasum
require_command base64
require_command curl

tmpdir="$(mktemp -d)"
# shellcheck disable=SC2064 # reason: cleanup must capture the temp dir path at definition time
trap "rm -rf '$tmpdir'" EXIT

mkdir -p "$tmpdir/bin" "$tmpdir/cache"

cat >"$tmpdir/bin/jq" <<'JQ'
#!/usr/bin/env bash
set -euo pipefail
exec /usr/bin/jq "$@"
JQ
chmod +x "$tmpdir/bin/jq"

cat >"$tmpdir/bin/sha256sum" <<'SHA'
#!/usr/bin/env bash
set -euo pipefail
exec /usr/bin/shasum -a 256 "$@"
SHA
chmod +x "$tmpdir/bin/sha256sum"

printf 'current' >"$tmpdir/current"
hash="$(/usr/bin/shasum -a 256 "$tmpdir/current" | awk '{print $1}')"
sri="sha256-$(python3 -c "import base64,binascii; print(base64.b64encode(binascii.unhexlify('$hash')).decode())")"

machine="$(uname -m)"
case "$machine" in
arm64) machine="aarch64" ;;
esac
platform="$machine-$(uname -s | tr '[:upper:]' '[:lower:]')"
cat >"$tmpdir/lockfile.json" <<JSON
{
  "nix-index-database": {
    "$platform": {
      "hash": "$sri",
      "url": "file://$tmpdir/remote"
    }
  }
}
JSON

printf 'current' >"$tmpdir/cache/files"
cp "$tmpdir/cache/files" "$tmpdir/remote"

"$SCRIPT_UNDER_TEST" "$tmpdir/cache" "$tmpdir/bin/sha256sum" "$tmpdir/bin/jq" "$tmpdir/lockfile.json" >"$tmpdir/out1" 2>&1
if grep -q "already current" "$tmpdir/out1"; then
  assert_pass "update-nix-index no-op when hash matches"
else
  assert_fail "update-nix-index no-op when hash matches" "expected 'already current' in output"
fi

printf 'new-db' >"$tmpdir/remote"
new_hash="$(/usr/bin/shasum -a 256 "$tmpdir/remote" | awk '{print $1}')"
new_sri="sha256-$(python3 -c "import base64,binascii; print(base64.b64encode(binascii.unhexlify('$new_hash')).decode())")"
python3 - "$tmpdir/lockfile.json" "$platform" "$new_sri" "$tmpdir/remote" <<'PY'
import json, sys
path, platform, sri, url = sys.argv[1:5]
d = json.load(open(path))
d["nix-index-database"][platform]["hash"] = sri
d["nix-index-database"][platform]["url"] = f"file://{url}"
json.dump(d, open(path, "w"))
PY

"$SCRIPT_UNDER_TEST" "$tmpdir/cache" "$tmpdir/bin/sha256sum" "$tmpdir/bin/jq" "$tmpdir/lockfile.json" >"$tmpdir/out2" 2>&1
if grep -q "done" "$tmpdir/out2"; then
  assert_pass "update-nix-index reports refresh"
else
  assert_fail "update-nix-index reports refresh" "expected 'done' in output"
fi
got="$(cat "$tmpdir/cache/files")"
if [ "$got" = "new-db" ]; then
  assert_pass "update-nix-index rewrites when hash differs"
else
  assert_fail "update-nix-index rewrites when hash differs" "got '$got'"
fi

finish_tests
