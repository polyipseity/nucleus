#!/usr/bin/env bash
# Hermes profile config, identity, and skill payloads must exist in user scope.

set -Eeuo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=./test-lib.sh
. "$SCRIPT_DIR/test-lib.sh"

REPO_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/../.." && pwd -P)"
readonly REPO_ROOT

require_command python3 "registry and activation wiring checks are Python-based"

CLI_CONFIG="$REPO_ROOT/src/users/default/hermes/config.yaml"
GATEWAY_CONFIG="$REPO_ROOT/src/users/default/hermes/profiles/gateway/config.yaml"
SOUL="$REPO_ROOT/src/users/default/hermes/SOUL.md"
MODULE="$REPO_ROOT/src/modules/hermes-agent.nix"
REGISTRY="$REPO_ROOT/src/modules/configs/harness-models.json"
MERGE_PY="$REPO_ROOT/src/scripts/agents/merge-harness-models.py"
readonly CLI_CONFIG GATEWAY_CONFIG SOUL MODULE REGISTRY MERGE_PY

section 1 "Hermes profile payloads"

if test -f "$CLI_CONFIG"; then
  assert_pass "cli config exists" test -f "$CLI_CONFIG"
else
  assert_fail "cli config exists" "missing src/users/default/hermes/config.yaml"
fi

if test -f "$GATEWAY_CONFIG"; then
  assert_pass "gateway config exists" test -f "$GATEWAY_CONFIG"
else
  assert_fail "gateway config exists" "missing src/users/default/hermes/profiles/gateway/config.yaml"
fi

if test -f "$CLI_CONFIG" && grep -q 'backend: local' "$CLI_CONFIG"; then
  assert_pass "cli terminal is local" grep -q 'backend: local' "$CLI_CONFIG"
else
  assert_fail "cli terminal is local" "no 'backend: local' in src/users/default/hermes/config.yaml"
fi

if test -f "$GATEWAY_CONFIG" && grep -q 'backend: docker' "$GATEWAY_CONFIG"; then
  assert_pass "gateway terminal is docker" grep -q 'backend: docker' "$GATEWAY_CONFIG"
else
  assert_fail "gateway terminal is docker" "no 'backend: docker' in gateway config.yaml"
fi

if test -f "$GATEWAY_CONFIG" && grep -q 'mode: smart' "$GATEWAY_CONFIG"; then
  assert_pass "gateway uses smart approvals" grep -q 'mode: smart' "$GATEWAY_CONFIG"
else
  assert_fail "gateway uses smart approvals" "no 'mode: smart' in gateway config.yaml"
fi

if test -f "$SOUL"; then
  assert_pass "soul exists" test -f "$SOUL"
else
  assert_fail "soul exists" "missing src/users/default/hermes/SOUL.md"
fi

section 2 "Activation wiring"

if _order_check="$(
  python3 - "$MODULE" 2>&1 <<'PY'
import re
import sys

text = open(sys.argv[1], encoding="utf-8").read()
starts = list(re.finditer(r'^  home\.activation\.([A-Za-z0-9_]+)\s*=', text, re.M))
blocks = {
    match.group(1): text[match.end() : starts[i + 1].start() if i + 1 < len(starts) else len(text)]
    for i, match in enumerate(starts)
}
failures = []

def quoted_names(value):
    return set(re.findall(r'"([^"]+)"', value))

prepare = blocks.get("prepareHermesProfileDirs")
if prepare is None:
    failures.append("no prepareHermesProfileDirs activation entry")
else:
    before = re.search(r'lib\.hm\.dag\.entryBefore\s+\[\s*([^\]]*)\]', prepare)
    if before is None:
        failures.append("prepare has no entryBefore ordering")
    else:
        names = quoted_names(before.group(1))
        if names != {"sops-nix"}:
            failures.append("prepare does not run only before sops-nix: " + ", ".join(sorted(names)))
    if "mkdir -p" not in prepare:
        failures.append("prepare does not create directories")
    dirs = set(re.findall(r'\$\{config\.home\.homeDirectory\}(/[A-Za-z0-9_./-]+)', prepare))
    if dirs != {"/.hermes", "/.hermes/profiles/gateway"}:
        failures.append("prepare creates unexpected paths: " + ", ".join(sorted(dirs)))

seed = blocks.get("seedHermesUserConfig")
if seed is None:
    failures.append("no seedHermesUserConfig activation entry")
else:
    between = re.search(
        r'lib\.hm\.dag\.entryBetween\s+\[\s*([^\]]*)\]\s+\[\s*([^\]]*)\]',
        seed,
        re.S,
    )
    if between is None:
        failures.append("seed has no entryBetween ordering")
    else:
        missing_before = {"hermesAgentSetup"} - quoted_names(between.group(1))
        if missing_before:
            failures.append("seed does not run before: " + ", ".join(sorted(missing_before)))
        missing_after = {"prepareHermesProfileDirs", "linkGeneration"} - quoted_names(between.group(2))
        if missing_after:
            failures.append("seed does not run after: " + ", ".join(sorted(missing_after)))

if failures:
    raise SystemExit("; ".join(failures))
PY
)"; then
  assert_pass "prepare precedes sops-nix and seed follows prepare and linkGeneration"
else
  assert_fail "prepare precedes sops-nix and seed follows prepare and linkGeneration" "$_order_check"
fi

section 3 "Hermes harness model registry"

if _registry_check="$(
  python3 - "$REPO_ROOT" "$REGISTRY" "$MERGE_PY" 2>&1 <<'PY'
import json
import subprocess
import sys
import tempfile
from pathlib import Path

import yaml

repo = Path(sys.argv[1])
registry = Path(sys.argv[2])
merge_py = Path(sys.argv[3])
entries = json.loads(registry.read_text(encoding="utf-8"))["harnesses"]
rows = {entry["harness"]: entry for entry in entries if entry["harness"].startswith("hermes")}
expected_paths = {
    "hermes": "~/.hermes/config.yaml",
    "hermes-gateway": "~/.hermes/profiles/gateway/config.yaml",
}
if set(rows) != set(expected_paths):
    raise SystemExit(
        f"expected Hermes ids {sorted(expected_paths)}, got {sorted(rows)}"
    )

for harness, path in expected_paths.items():
    row = rows[harness]
    if row["path"] != path:
        raise SystemExit(f"{harness}: path is {row['path']}, expected {path}")
    if row["format"] != "yaml":
        raise SystemExit(f"{harness}: format is {row['format']}, expected yaml")
    slot = row["slot"]
    actual_slot = (
        slot.get("kind"),
        slot.get("listKey"),
        slot.get("itemKey"),
        slot.get("itemName"),
    )
    if actual_slot != ("yaml-named-item", "custom_providers", "name", "litellm"):
        raise SystemExit(f"{harness}: wrong slot {actual_slot}")

if rows["hermes"]["payload"] != rows["hermes-gateway"]["payload"]:
    raise SystemExit("the two Hermes rows name different payloads")
payload = yaml.safe_load((repo / rows["hermes"]["payload"]).read_text(encoding="utf-8"))

with tempfile.TemporaryDirectory(prefix="hermes-harness-rows-") as tmp:
    home = Path(tmp)
    targets = {}
    for harness, path in expected_paths.items():
        target = home / path[2:]
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(
            "custom_providers:\n  - name: litellm\n    base_url: http://old\n",
            encoding="utf-8",
        )
        targets[harness] = target

    result = subprocess.run(
        [
            sys.executable,
            str(merge_py),
            "--registry", str(registry),
            "--repo-root", str(repo),
            "--home", str(home),
            "--harness", "hermes",
            "--harness", "hermes-gateway",
        ],
        capture_output=True,
        text=True,
    )
    if result.returncode:
        raise SystemExit(f"merge failed: {result.stderr.strip()}")
    for harness, target in targets.items():
        merged = yaml.safe_load(target.read_text(encoding="utf-8"))
        owned = [item for item in merged["custom_providers"] if item.get("name") == "litellm"]
        if len(owned) != 1:
            raise SystemExit(f"{harness}: found {len(owned)} litellm items")
        if owned[0] != payload:
            raise SystemExit(f"{harness}: merged item {owned[0]} != payload {payload}")
PY
)"; then
  assert_pass "both Hermes paths merge their registered payload"
else
  assert_fail "both Hermes paths merge their registered payload" "$_registry_check"
fi

section 4 "Hermes skill bundle sources"

if _skill_check="$(
  python3 - "$REPO_ROOT" "$MODULE" 2>&1 <<'PY'
import re
import sys
from pathlib import Path

repo = Path(sys.argv[1])
text = Path(sys.argv[2]).read_text(encoding="utf-8")
names_block = re.search(r'^  hermesSkillNames = \[(.*?)^  \];', text, re.M | re.S)
if names_block is None:
    raise SystemExit("no hermesSkillNames declaration in module")
names = re.findall(r'"([^"]+)"', names_block.group(1))
if not names:
    raise SystemExit("hermesSkillNames has no entries")

# Bundles are nested under agents/skills, so selectFile must split the path.
if 'overlay.selectFile "agents" "skills/${name}"' not in text:
    raise SystemExit("skill seeding does not select agents/skills/${name}")
if 'overlay.selectFirstLevelEntry "agents"' in text:
    raise SystemExit('skill seeding still calls selectFirstLevelEntry "agents"')
if 'overlay.selectFirstLevelEntry "hermes" "skills"' not in text:
    raise SystemExit('hermes skills directory must still use selectFirstLevelEntry "hermes" "skills"')

skills_dir = repo / "src/users/default/agents/skills"
for name in names:
    if not (skills_dir / name).is_dir():
        raise SystemExit(f"no skill bundle at src/users/default/agents/skills/{name}")
PY
)"; then
  assert_pass "skill bundles resolve through agents/skills"
else
  assert_fail "skill bundles resolve through agents/skills" "$_skill_check"
fi

finish_tests
