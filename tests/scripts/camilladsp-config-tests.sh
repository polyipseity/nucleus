#!/usr/bin/env bash
# Tests for src/modules/configs/camilladsp/configs/: a config whose devices.*.type
# is Alsa may name that device only as null or as an ALSA identifier, because an
# ALSA backend cannot open a CoreAudio or WASAPI name. A copied loopback name is a
# chain that cannot start on that host. The ALSA default device that feeds the
# loopback must also be the capture side's pair, so the two ends cannot drift apart
# in a one-sided edit.
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
REPO_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/../.." && pwd -P)"
# shellcheck source=tests/scripts/test-lib.sh
. "$SCRIPT_DIR/test-lib.sh"

CONFIG_DIR="$REPO_ROOT/src/modules/configs/camilladsp/configs"
ASOUND_CONF="$REPO_ROOT/src/modules/configs/asound/asound.conf"

require_command python3 "the CamillaDSP configs are YAML and PyYAML is the parser the suite uses"
require_command mktemp "the case runs from a private helper file"

helper="$(mktemp -t camilladsp-config-tests)"
cat >"$helper" <<'PY'
import os
import pathlib
import re
import sys

import yaml

# An Alsa device is opened through libasound, so only ALSA resolves the name: a
# bare PCM name or one of the standard ALSA prefixes. Anything else is a name
# from a platform backend that happens to share the devices block.
ALSA_PREFIXES = ("hw:", "plughw:", "sysdefault:", "default", "dsnoop:")

# The hw:<card>,<device>,<subdevice> form is the only one that names a card and a
# device number separately, which is what makes the playback/capture pairing
# checkable without pinning the card name.
HW_DEVICE = re.compile(r"^hw:([^,\s]+),(\d+),(\d+)$")


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


def default_slave(asound):
    """Return (raw, (card, device, subdevice)) for pcm.!default's slave.pcm, or None."""
    block = re.search(r"pcm\.!default\s*\{([^}]*)\}", asound.read_text())
    if block is None:
        return None
    slave = re.search(r'slave\.pcm\s+"?([^"\s}]+)"?', block.group(1))
    if slave is None:
        return None
    parsed = HW_DEVICE.match(slave.group(1))
    if parsed is None:
        return None
    return slave.group(1), parsed.groups()


def case_default_device_pairs_with_capture():
    asound = pathlib.Path(os.environ["ASOUND_CONF"])
    assert asound.is_file(), f"{asound} does not exist"
    slave = default_slave(asound)
    assert slave is not None, (
        f"{asound}: no pcm.!default slave.pcm of the hw:<card>,<device>,<subdevice> shape"
    )
    raw, (card, playback_device, subdevice) = slave
    # ref: Documentation/sound/cards/aloop.rst -- a loopback card's playback device 0
    # pairs with its capture device 1, so the capture side sits one above the
    # playback side the default device names.
    capture_device = str(int(playback_device) + 1)

    # Every host's config directory is scanned on purpose: the Alsa configs are the
    # NixOS ones, and an Alsa hw: capture anywhere else would be a host that needs
    # this file too, so a failure there is correct rather than a false positive.
    unpaired = []
    mismatched = []
    paired = 0
    capture_count = 0
    for path, key, device in alsa_endpoints(pathlib.Path(os.environ["CONFIG_DIR"])):
        if key != "capture":
            continue
        capture_count += 1
        capture = HW_DEVICE.match(device) if isinstance(device, str) else None
        if capture is None:
            unpaired.append(f"{path}: capture device {device!r}")
            continue
        paired += 1
        if capture.groups() != (card, capture_device, subdevice):
            mismatched.append(
                f"{path}: capture device {device!r} is not the other side of {asound} slave.pcm {raw!r}"
            )
    assert paired == capture_count, (
        f"{paired} of {capture_count} Alsa capture endpoints under {os.environ['CONFIG_DIR']} "
        f"cannot be paired with {asound}: " + "; ".join(unpaired)
    )
    assert paired > 0, (
        f"no Alsa capture endpoint under {os.environ['CONFIG_DIR']}, "
        f"so the pairing of {asound} was never exercised"
    )
    assert not mismatched, "; ".join(mismatched)


CASES = {
    "alsa_devices_name_alsa_devices": case_alsa_devices_name_alsa_devices,
    "default_device_pairs_with_capture": case_default_device_pairs_with_capture,
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
  if output=$(PYTHONDONTWRITEBYTECODE=1 CONFIG_DIR="$CONFIG_DIR" ASOUND_CONF="$ASOUND_CONF" \
    python3 "$helper" "$case_name" 2>&1); then
    assert_pass "$case_name"
  else
    assert_fail "$case_name" "${output:-exited non-zero without a message}"
  fi
}

section 1 "ALSA device names"
run_case alsa_devices_name_alsa_devices

section 2 "default device pairing"
run_case default_device_pairs_with_capture

finish_tests
