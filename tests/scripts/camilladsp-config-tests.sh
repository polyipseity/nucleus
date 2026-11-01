#!/usr/bin/env bash
# Tests for src/modules/configs/camilladsp/configs/: a config whose devices.*.type
# is Alsa may name that device only as null or as an ALSA identifier, because an
# ALSA backend cannot open a CoreAudio or WASAPI name. A copied loopback name is a
# chain that cannot start on that host.
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
REPO_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/../.." && pwd -P)"
# shellcheck source=tests/scripts/test-lib.sh
. "$SCRIPT_DIR/test-lib.sh"

CONFIG_DIR="$REPO_ROOT/src/modules/configs/camilladsp/configs"

require_command python3 "the CamillaDSP configs are YAML and PyYAML is the parser the suite uses"
require_command mktemp "the case runs from a private helper file"

helper="$(mktemp -t camilladsp-config-tests)"
cat >"$helper" <<'PY'
import os
import pathlib
import sys

import yaml

# An Alsa device is opened through libasound, so only ALSA resolves the name: a
# bare PCM name or one of the standard ALSA prefixes. Anything else is a name
# from a platform backend that happens to share the devices block.
ALSA_PREFIXES = ("hw:", "plughw:", "sysdefault:", "default", "dsnoop:")


def alsa_endpoints(config_dir):
    """Yield (path, key, device) for every Alsa devices.<key> block, deduped by file."""
    seen = set()
    for path in sorted(config_dir.glob("**/*.yml")):
        resolved = path.resolve()
        if resolved in seen:
            continue
        seen.add(resolved)
        config = yaml.safe_load(path.read_text()) or {}
        devices = config.get("devices") or {}
        for key, endpoint in devices.items():
            if not isinstance(endpoint, dict) or endpoint.get("type") != "Alsa":
                continue
            yield path, key, endpoint.get("device")


def case_alsa_devices_name_alsa_devices():
    config_dir = pathlib.Path(os.environ["CONFIG_DIR"])
    problems = []
    inspected = 0
    for path, key, device in alsa_endpoints(config_dir):
        inspected += 1
        if device is None:
            continue
        if not isinstance(device, str) or not device.startswith(ALSA_PREFIXES):
            problems.append(f"{path}: devices.{key}.device = {device!r}")
    assert inspected > 0, f"no Alsa device found under {config_dir}, so the property passed vacuously"
    assert not problems, "an Alsa backend cannot open " + "; ".join(problems)


CASES = {
    "alsa_devices_name_alsa_devices": case_alsa_devices_name_alsa_devices,
}


def main():
    name = sys.argv[1]
    if name not in CASES:
        print(f"unknown case: {name}", file=sys.stderr)
        return 2
    try:
        CASES[name]()
    except AssertionError as error:
        print(f"{name}: {error}", file=sys.stderr)
        return 1
    return 0


sys.exit(main())
PY

run_case() { # <case name>
  local case_name="$1"
  local output
  if output=$(PYTHONDONTWRITEBYTECODE=1 CONFIG_DIR="$CONFIG_DIR" python3 "$helper" "$case_name" 2>&1); then
    assert_pass "$case_name"
  else
    assert_fail "$case_name" "${output:-exited non-zero without a message}"
  fi
}

section 1 "ALSA device names"
run_case alsa_devices_name_alsa_devices

finish_tests
