#!/usr/bin/env bash
# Tests for the POSIX provision-harness-models activation entrypoint.
# Task B5: harness selection, host-split paths, and hard errors.
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
REPO_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/../.." && pwd -P)"
# shellcheck source=./test-lib.sh
. "$SCRIPT_DIR/test-lib.sh"

require_command python3 "the merge tool is a Python script"
require_command jq "the activation entrypoint reads the registry with jq"

ENTRYPOINT="$REPO_ROOT/src/scripts/agents/provision-harness-models.sh"
MERGE_TOOL="$REPO_ROOT/src/scripts/agents/merge-harness-models.py"
REGISTRY="$REPO_ROOT/src/modules/configs/harness-models.json"
HOST_KEY='NixOS'
PYTHON_BIN="$(command -v python3)"
JQ_BIN="$(command -v jq)"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

HOME_DIR="$WORK/home"
EMPTY_HOME="$WORK/empty-home"
mkdir -p "$HOME_DIR/.pi/agent" "$HOME_DIR/.config/opencode" "$HOME_DIR/.claude" "$HOME_DIR/.config/Code/User" "$EMPTY_HOME"

OUT="$WORK/out"
ERR="$WORK/err"

if "$ENTRYPOINT" "$PYTHON_BIN" "$JQ_BIN" "$REPO_ROOT" "$REGISTRY" "$HOST_KEY" "$HOME_DIR" >"$OUT" 2>"$ERR"; then
  assert_pass 'entrypoint merges installed harnesses'
else
  assert_fail 'entrypoint merges installed harnesses' "rc=$? out=$(cat "$OUT") err=$(cat "$ERR")"
fi

for target in \
  "$HOME_DIR/.pi/agent/models.json" \
  "$HOME_DIR/.config/opencode/opencode.jsonc" \
  "$HOME_DIR/.claude/settings.json" \
  "$HOME_DIR/.config/Code/User/chatLanguageModels.json"; do
  if [ -f "$target" ]; then
    assert_pass "created $target"
  else
    assert_fail "created $target" 'target is absent'
  fi
done

for absent in "$HOME_DIR/.copilot" "$HOME_DIR/.hermes" "$HOME_DIR/.codex" "$HOME_DIR/Library" "$HOME_DIR/AppData"; do
  if [ -e "$absent" ]; then
    assert_fail "no directory for absent harness at $absent" 'path was created'
  else
    assert_pass "no directory for absent harness at $absent"
  fi
done

for harness in copilot hermes codex; do
  if grep -q "skipped $harness: no config directory" "$OUT"; then
    assert_pass "reported skipped harness $harness"
  else
    assert_fail "reported skipped harness $harness" "out=$(cat "$OUT")"
  fi
done

if "$PYTHON_BIN" - "$HOME_DIR" <<'PY'
import json
import sys
from pathlib import Path

home = Path(sys.argv[1])
pi = json.loads((home / '.pi/agent/models.json').read_text())
assert 'litellm' in pi['providers']
claude = json.loads((home / '.claude/settings.json').read_text())
assert claude['env']['ANTHROPIC_MODEL'] == 'default'
vscode = json.loads((home / '.config/Code/User/chatLanguageModels.json').read_text())
assert [item['name'] for item in vscode] == ['LiteLLM']
PY
then
  assert_pass 'merged slots carry the registry payloads'
else
  assert_fail 'merged slots carry the registry payloads' 'a target slot did not match its payload'
fi

cp "$HOME_DIR/.pi/agent/models.json" "$WORK/models.snapshot"
if "$ENTRYPOINT" "$PYTHON_BIN" "$JQ_BIN" "$REPO_ROOT" "$REGISTRY" "$HOST_KEY" "$HOME_DIR" >"$OUT" 2>"$ERR"; then
  if cmp -s "$WORK/models.snapshot" "$HOME_DIR/.pi/agent/models.json"; then
    assert_pass 'repeated activation is idempotent'
  else
    assert_fail 'repeated activation is idempotent' 'target changed on the second run'
  fi
else
  assert_fail 'repeated activation is idempotent' "rc=$? out=$(cat "$OUT") err=$(cat "$ERR")"
fi

if "$PYTHON_BIN" "$MERGE_TOOL" --check --repo-root "$REPO_ROOT" --home "$HOME_DIR" --host "$HOST_KEY" \
  --harness pi --harness opencode --harness claude --harness vscode >"$OUT" 2>"$ERR"; then
  assert_pass 'merge --check passes for the installed harnesses'
else
  assert_fail 'merge --check passes for the installed harnesses' "out=$(cat "$OUT") err=$(cat "$ERR")"
fi

if "$ENTRYPOINT" "$WORK/no-python" "$JQ_BIN" "$REPO_ROOT" "$REGISTRY" "$HOST_KEY" "$HOME_DIR" >"$OUT" 2>"$ERR"; then
  assert_fail 'missing python is a hard error' "rc=0 out=$(cat "$OUT")"
elif grep -q 'python interpreter not found' "$ERR"; then
  assert_pass 'missing python is a hard error'
else
  assert_fail 'missing python is a hard error' "err=$(cat "$ERR")"
fi

if "$ENTRYPOINT" "$PYTHON_BIN" "$JQ_BIN" "$REPO_ROOT" "$WORK/no-registry.json" "$HOST_KEY" "$HOME_DIR" >"$OUT" 2>"$ERR"; then
  assert_fail 'missing registry is a hard error' "rc=0 out=$(cat "$OUT")"
elif grep -q 'registry not found' "$ERR"; then
  assert_pass 'missing registry is a hard error'
else
  assert_fail 'missing registry is a hard error' "err=$(cat "$ERR")"
fi

if "$ENTRYPOINT" "$PYTHON_BIN" "$JQ_BIN" "$REPO_ROOT" "$REGISTRY" "$HOST_KEY" "$EMPTY_HOME" >"$OUT" 2>"$ERR"; then
  if grep -q 'no installed harness config directories' "$OUT"; then
    assert_pass 'no installed harnesses is a reported skip'
  else
    assert_fail 'no installed harnesses is a reported skip' "out=$(cat "$OUT")"
  fi
else
  assert_fail 'no installed harnesses is a reported skip' "rc=$? err=$(cat "$ERR")"
fi

if [ -n "$(find "$EMPTY_HOME" -mindepth 1 -print -quit)" ]; then
  assert_fail 'empty home stays empty' 'entrypoint created a harness directory'
else
  assert_pass 'empty home stays empty'
fi

finish_tests
