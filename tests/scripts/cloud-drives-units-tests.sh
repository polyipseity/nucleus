#!/usr/bin/env bash
# cloud-drives-units-tests.sh — argv correctness of the generated systemd unit scripts.
#
# The NixOS units create their mount point and unmount their volume via
# `pkgs.writeShellScript` bodies generated in src/modules/cloud-drives.nix.  A mount
# point containing a space is the failure mode these tests exist for: when the path was
# interpolated into a `/bin/sh -c '…'` line, `lib.escapeShellArg`'s single quotes were
# consumed by the OUTER parse, the then-bare path was handed to `sh -c`, and it split at
# the first space — `fusermount3 -u /Users/a` — leaving the volume mounted and the stale
# mount blocking the next start.
#
# WHY this parses the Nix source instead of evaluating the module: the bodies are
# `writeShellScript` derivations, and evaluating the module requires nixpkgs, which is
# unreachable offline in this environment.  Extraction is the only viable approach here;
# every ASSERTION is behavioural — the extracted body is executed with a space-containing
# path and the recorded argv is inspected, rather than a string being pattern-matched.
# shellcheck shell=bash
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=./test-lib.sh
. "$SCRIPT_DIR/test-lib.sh"

REPO_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/../.." && pwd -P)"
NIX_FILE="$REPO_ROOT/src/modules/cloud-drives.nix"

# A mount point with a space in it, escaped the way lib.escapeShellArg escapes it.
MOUNT_POINT="/Users/a b/clouds/iCloud"
ESCAPED="'$MOUNT_POINT'"
# The literal `${lib.escapeShellArg mountPoint}` expression as it appears in the Nix source.
# check-suppress:suppression_doc: shellcheck SC2016 is expected here; the token must stay literal
# shellcheck disable=SC2016 # reason: this is the literal Nix text to be matched and substituted, not a shell expansion
TOKEN='${lib.escapeShellArg mountPoint}'

WORK="$(mktemp -d)"
SHIM="$WORK/shim"
mkdir -p "$SHIM"
trap 'rm -rf "$WORK"' EXIT

# make_shim NAME — install a recorder that logs its argv, one argument per line.
make_shim() {
  local name="$1"
  cat >"$SHIM/$name" <<'SHIM_BODY'
#!/bin/sh
{
  printf 'argc=%d\n' "$#"
  for _a in "$@"; do
    printf 'arg=<%s>\n' "$_a"
  done
} >>"$REC"
SHIM_BODY
  chmod +x "$SHIM/$name"
}

make_shim fusermount3
make_shim mkdir

# extract_script_body NAME — print the `writeShellScript "NAME" ''…''` body.
# Prints nothing when the Nix file no longer contains such a body, which the caller
# treats as a failure: a reverted fix must fail loudly rather than skip.
extract_script_body() {
  awk -v name="$1" -v end="'';" '
    found && $1 == end { exit }
    found { print }
    index($0, "writeShellScript \"" name "\" ") { found = 1 }
  ' "$NIX_FILE"
}

# run_body BODY PROGRAM — execute BODY with the shims on PATH and print the recorder log.
run_body() {
  local body="$1" program="$2" rec="$WORK/$2.rec"
  printf '#!/bin/sh\n%s\n' "$body" >"$WORK/body.sh"
  : >"$rec"
  PATH="$SHIM:$PATH" REC="$rec" sh "$WORK/body.sh" || true
  cat "$rec"
}

# check_body NAME PROGRAM — assert the generated body delivers a space-containing path
# as exactly ONE argument, and that it does not re-introduce the nested quoting.
check_body() {
  local name="$1" program="$2"
  local body
  body="$(extract_script_body "$name")"
  if [ -z "$body" ]; then
    assert_fail "$name: body extracted" "no writeShellScript \"$name\" body found in cloud-drives.nix"
    return
  fi
  assert_pass "$name: body extracted"

  if printf '%s' "$body" | grep -q "sh -c"; then
    assert_fail "$name: no nested sh -c" "body still nests a command inside sh -c"
  else
    assert_pass "$name: no nested sh -c"
  fi

  local log
  log="$(run_body "${body//$TOKEN/$ESCAPED}" "$program")"
  if printf '%s\n' "$log" | grep -qxF "arg=<$MOUNT_POINT>"; then
    assert_pass "$name: space-containing path arrives as one argument"
  else
    assert_fail "$name: space-containing path arrives as one argument" "recorder saw: $(printf '%s' "$log" | tr '\n' ' ')"
  fi
}

section "1" "generated systemd unit scripts keep a space-containing path whole"

# Banned-pattern check (permitted form per the testing guidelines): no unit command may
# nest a command inside `sh -c '…'`, which is the construction that let lib.escapeShellArg's
# quotes be consumed by the outer parse.  Comment lines are skipped, otherwise the WHY
# comments that DESCRIBE the defect would register as occurrences OF it.
offenders="$(awk -v pat="sh -c '" '$0 ~ pat && $0 !~ /^[[:space:]]*#/ { print NR ": " $0 }' "$NIX_FILE")"
if [ -z "$offenders" ]; then
  assert_pass "no sh -c quoting in generated unit commands"
else
  assert_fail "no sh -c quoting in generated unit commands" "$offenders"
fi

check_body "cloud-mount-unmount" fusermount3
check_body "cloud-mount-mkdir" mkdir

finish_tests
