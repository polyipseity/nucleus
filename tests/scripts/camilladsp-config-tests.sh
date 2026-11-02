#!/usr/bin/env bash
# Tests for src/modules/configs/camilladsp/configs/: a config whose devices.*.type
# is Alsa may name that device only as null or as an ALSA identifier, because an
# ALSA backend cannot open a CoreAudio or WASAPI name. A copied loopback name is a
# chain that cannot start on that host. The ALSA default device that feeds the
# loopback must also be the capture side's pair, so the two ends cannot drift apart
# in a one-sided edit, and no playback device may resolve back into that loopback.
# A captured name also belongs to one backend only, and a Wasapi capture with a null
# device reads system audio only when it says it is loopback.
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
# from a platform backend that happens to share the devices block. The tuple is
# the set this repo uses today, not ALSA's whole PCM namespace, so a new name such
# as `dmix:` fails here by design; widening it is the change the default-device
# WHY in src/hosts/NixOS/default.nix already anticipates.
ALSA_PREFIXES = ("hw:", "plughw:", "sysdefault:", "default", "dsnoop:")

# Prefixes whose remainder addresses a card, so the same loopback can be spelled
# `hw:Loopback,0,0`, `plughw:Loopback`, or `sysdefault:CARD=Loopback`.
CARD_PREFIXES = ("hw:", "plughw:", "sysdefault:", "default:", "dsnoop:")

# The hw:<card>,<device>,<subdevice> form is the only one that names a card and a
# device number separately, which is what makes the playback/capture pairing
# checkable without pinning the card name.
HW_DEVICE = re.compile(r"^hw:([^,\s]+),(\d+),(\d+)$")


def all_endpoints(config_dir):
    """Yield (path, key, endpoint) for every devices.<key> block, deduped by file."""
    seen = set()
    for path in sorted(config_dir.glob("**/*.yml")):
        resolved = path.resolve()
        if resolved in seen:
            continue
        seen.add(resolved)
        config = yaml.safe_load(path.read_text()) or {}
        devices = config.get("devices") or {}
        for key, endpoint in devices.items():
            if not isinstance(endpoint, dict):
                continue
            yield path, key, endpoint


def alsa_endpoints(config_dir):
    """Yield (path, key, device) for every Alsa devices.<key> block, deduped by file."""
    for path, key, endpoint in all_endpoints(config_dir):
        if endpoint.get("type") == "Alsa":
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


def names_card(raw, card):
    """True when an ALSA PCM name addresses `card`, however the spelling is prefixed."""
    name = raw
    for prefix in CARD_PREFIXES:
        if name.startswith(prefix):
            name = name[len(prefix) :]
            break
    # `sysdefault:CARD=<card>` and `default:CARD=<card>` name the card as a keyed
    # value; the hw-style spellings put it first and may omit device and subdevice.
    keyed = re.match(r"CARD=(?P<card>[^,]+)", name, re.IGNORECASE)
    head = keyed if keyed is not None else re.match(r"(?P<card>[^,=]+)", name)
    return head is not None and head.group("card").lower() == card.lower()


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
    self_feeding = []
    paired = 0
    capture_count = 0
    for path, key, device in alsa_endpoints(pathlib.Path(os.environ["CONFIG_DIR"])):
        if key == "playback":
            # `default` now resolves through this file into the loopback, and every
            # name on that card does too, however it is prefixed, so playback has to
            # stay away from both or the daemon plays back what it just captured.
            if not isinstance(device, str):
                continue
            if device == "default":
                self_feeding.append(f"{path}: playback device {device!r} resolves through the ALSA default")
            elif names_card(device, card):
                self_feeding.append(f"{path}: playback device {device!r} names the loopback card {card!r}")
            continue
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
    assert not self_feeding, (
        f"an Alsa playback device resolves through {asound} back into the loopback it captures from: "
        + "; ".join(self_feeding)
    )


def case_backend_device_names():
    config_dir = pathlib.Path(os.environ["CONFIG_DIR"])
    wrong_backend = []
    missing_loopback = []
    wasapi_capture = 0
    # A device name belongs to one backend. BlackHole is a macOS driver, so a
    # Wasapi or Alsa endpoint naming it cannot open on that host, and a Wasapi
    # capture with a null device needs loopback: true or it captures the
    # microphone instead of system audio.
    for path, key, endpoint in all_endpoints(config_dir):
        device = endpoint.get("device")
        kind = endpoint.get("type")
        if isinstance(device, str) and "BlackHole" in device and kind != "CoreAudio":
            wrong_backend.append(
                f"{path}: devices.{key}.device = {device!r} is a CoreAudio name under {kind}"
            )
        if key == "capture" and kind == "Wasapi":
            wasapi_capture += 1
            if device is None and endpoint.get("loopback") is not True:
                missing_loopback.append(
                    f"{path}: Wasapi capture with no device needs loopback: true"
                )
    assert wasapi_capture > 0, (
        f"no Wasapi capture endpoint under {config_dir}, so the loopback property passed vacuously"
    )
    assert not wrong_backend, "a device name belongs to one backend: " + "; ".join(wrong_backend)
    assert not missing_loopback, "; ".join(missing_loopback)


CASES = {
    "alsa_devices_name_alsa_devices": case_alsa_devices_name_alsa_devices,
    "backend_device_names": case_backend_device_names,
    "default_device_pairs_with_capture": case_default_device_pairs_with_capture,
}


def main():
    name = sys.argv[1]
    if name not in CASES:
        sys.exit(f"unknown case: {name}")
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

section 3 "backend device names"
run_case backend_device_names

finish_tests
