#!/usr/bin/env bash
# Tests for src/scripts/services/camilladsp-heartbeat.py: default-output
# detection, device enumeration and its cache, the push decision and the config
# fingerprint.
#
# The daemon is a Python module, so each case runs in its own interpreter with
# the backend functions replaced by fixtures. Nothing here touches real audio
# hardware, and XDG_STATE_HOME is redirected into a temp directory per case.
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
REPO_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/../.." && pwd -P)"
# shellcheck source=tests/scripts/test-lib.sh
. "$SCRIPT_DIR/test-lib.sh"

CDSP_MODULE="$REPO_ROOT/src/scripts/services/camilladsp-heartbeat.py"

require_command python3 "the CamillaDSP heartbeat is a Python daemon and its tests import it"
require_command mktemp "each test case needs a private state directory"

init_test_state

helper="$(mktemp -t camilladsp-heartbeat-tests)"
cat >"$helper" <<'PY'
import importlib.util
import os
import pathlib
import sys
import tempfile

spec = importlib.util.spec_from_file_location("cdsp", os.environ["CDSP_MODULE"])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)


class Case:
    """One isolated heartbeat module with fake audio backends."""

    def __init__(self):
        self.dir = pathlib.Path(tempfile.mkdtemp(dir=os.environ["HOME"]))
        os.environ["XDG_STATE_HOME"] = str(self.dir / "state")
        os.environ["CAMILLADSP_DEVICE_CACHE_TTL"] = "300"
        self.probe = "Speakers"
        self.devices = ["Headphones", "Speakers"]
        self.probe_calls = 0
        self.list_calls = 0
        m.probe_default_output = self._probe
        m.list_available_devices = self._list

    def _probe(self):
        self.probe_calls += 1
        return self.probe

    def _list(self, capture_device):
        self.list_calls += 1
        return list(self.devices)

    def config(self, playback=None, capture="BlackHole 2ch", name="config.yml"):
        text = (
            "devices:\n"
            f"  capture:\n    device: {capture}\n"
            "  playback:\n"
            f"    device: {playback if playback is not None else 'null'}\n"
            "    type: CoreAudio\n"
            "  samplerate: 48000\n"
            "filters:\n  volume:\n    type: Volume\n"
            "pipeline: []\n"
        )
        path = self.dir / name
        path.write_text(text)
        return path


def device_of(yaml_text):
    import yaml

    config = yaml.safe_load(yaml_text) or {}
    return (config.get("devices") or {}).get("playback", {}).get("device")


def case_passthrough():
    c = Case()
    original = c.config(playback="USB DAC").read_text()
    assert m.resolve_playback_device(c.dir / "config.yml") == original
    assert m.target_playback_device(c.dir / "config.yml") == "USB DAC"
    assert c.probe_calls == 0, "a fixed device must not touch the audio backend"


def case_patches_default_output():
    c = Case()
    config = c.config()
    resolved = m.resolve_playback_device(config)
    assert device_of(resolved) == "Speakers", device_of(resolved)
    assert c.probe_calls == 1


def case_rejects_capture_device():
    c = Case()
    c.probe = "BlackHole 2ch"
    config = c.config()
    assert device_of(m.resolve_playback_device(config)) == "Headphones"


def case_null_when_no_devices():
    c = Case()
    c.probe = "BlackHole 2ch"
    c.devices = []
    config = c.config()
    assert device_of(m.resolve_playback_device(config)) is None
    assert m.target_playback_device(config) == ""


def case_preserves_other_fields():
    import yaml

    c = Case()
    resolved = yaml.safe_load(m.resolve_playback_device(c.config()))
    assert resolved["devices"]["samplerate"] == 48000
    assert resolved["devices"]["playback"]["type"] == "CoreAudio"
    assert resolved["filters"]["volume"]["type"] == "Volume"
    assert resolved["pipeline"] == []


def case_all_devices_are_capture():
    c = Case()
    c.probe = "BlackHole 2ch"
    c.devices = ["BlackHole 2ch"]
    assert m.target_playback_device(c.config()) == "", "capture became playback"


def case_saved_used_when_no_default():
    c = Case()
    c.probe = "BlackHole 2ch"
    m.save_last_device("Headphones")
    assert device_of(m.resolve_playback_device(c.config())) == "Headphones"


def case_system_default_wins_over_saved():
    c = Case()
    m.save_last_device("Headphones")
    assert device_of(m.resolve_playback_device(c.config())) == "Speakers"


def case_saved_rejected_when_matches_capture():
    c = Case()
    c.probe = "BlackHole 2ch"
    m.save_last_device("BlackHole 2ch")
    assert device_of(m.resolve_playback_device(c.config())) == "Headphones"


def case_no_default_no_saved_falls_to_first_available():
    c = Case()
    c.probe = "BlackHole 2ch"
    assert device_of(m.resolve_playback_device(c.config())) == "Headphones"


def case_saved_match_capture_without_alternatives():
    c = Case()
    c.probe = "BlackHole 2ch"
    c.devices = ["BlackHole 2ch"]
    m.save_last_device("BlackHole 2ch")
    assert m.target_playback_device(c.config()) == "", "capture became playback"


def case_last_device_purged_when_gone():
    c = Case()
    c.probe = "BlackHole 2ch"
    c.devices = ["Headphones"]
    m.save_last_device("Unplugged")
    assert device_of(m.resolve_playback_device(c.config())) == "Headphones"
    assert m.load_last_device() is None, "a device that is gone must be forgotten"


def case_needs_push():
    assert m.needs_push("Running", "Speakers", "Speakers", False) is False
    assert m.needs_push("Running", "Headphones", "Speakers", False) is True
    assert m.needs_push("Running", "Speakers", "Speakers", True) is True
    assert m.needs_push("Running", "", "", False) is False
    assert m.needs_push("Stopped", "", "Speakers", False) is True
    assert m.needs_push("Paused", "Speakers", "Speakers", False) is True


def case_target_device():
    c = Case()
    fixed = c.config(playback="USB DAC")
    assert m.target_playback_device(fixed) == "USB DAC"
    null_device = c.config(name="null.yml")
    assert m.target_playback_device(null_device) == "Speakers"
    assert m.target_playback_device(c.dir / "absent.yml") == ""


def case_cache_reuse():
    c = Case()
    m.invalidate_device_cache()
    first = m.list_available_devices_cached("BlackHole 2ch")
    second = m.list_available_devices_cached("BlackHole 2ch")
    assert first == second == ["Headphones", "Speakers"]
    assert c.list_calls == 1, f"expected one enumeration, saw {c.list_calls}"


def case_cache_misses():
    c = Case()
    c.devices = ["Headphones", "Speakers"]
    m.invalidate_device_cache()
    m.list_available_devices_cached("BlackHole 2ch")
    # A different capture device invalidates the entry.
    m.list_available_devices_cached("USB Mic")
    assert c.list_calls == 2, c.list_calls
    # A required device missing from the cache forces a fresh read on this tick.
    c.devices = ["Headphones", "Speakers", "HDMI"]
    assert "HDMI" in m.list_available_devices_cached("USB Mic", "HDMI")
    assert c.list_calls == 3, c.list_calls
    # TTL zero always re-enumerates.
    os.environ["CAMILLADSP_DEVICE_CACHE_TTL"] = "0"
    m.list_available_devices_cached("USB Mic")
    assert c.list_calls == 4, c.list_calls


def case_config_change():
    c = Case()
    config = c.config()
    target = m.target_playback_device(config)
    assert m.config_changed(config, target) is True, "a missing push record counts as changed"
    m.record_push(m.config_fingerprint(config, target))
    assert m.config_changed(config, target) is False
    config.write_text(config.read_text().replace("samplerate: 48000", "samplerate: 44100"))
    assert m.config_changed(config, target) is True


def case_fingerprint_covers_device():
    c = Case()
    config = c.config(playback="Speakers")
    assert m.config_fingerprint(config, "Speakers") != m.config_fingerprint(config, "Headphones")


def case_linux_backends():
    outputs = {
        ("wpctl", "status"): (
            "Audio\n"
            " ├─ Sinks:\n"
            " │  *   52. Built-in Audio Analog Stereo        [vol: 1.00]\n"
            " │      53. HDMI Output                         [vol: 0.40]\n"
            " ├─ Sources:\n"
        ),
        ("pactl", "info"): "Server Name: pulseaudio\nDefault Sink: alsa_output.pci.analog-stereo\n",
        ("aplay", "-l"): "card 0: PCH [HDA Intel PCH], device 0: ALC295 Analog [ALC295 Analog]\n",
    }
    # WHY: the daemon keeps the substitutions the shell pipeline used, so the
    # default sink here is the id and description the GNU sed expression left.
    m._run = lambda command: outputs.get(tuple(command))
    assert m._linux_default_output() == "52. Built-in Audio Analog Stereo        [vol:"

    def only_pactl(command):
        return outputs.get(tuple(command)) if command[0] == "pactl" else None

    m._run = only_pactl
    assert m._linux_default_output() == "alsa_output.pci.analog-stereo"
    m._run = lambda command: outputs.get(tuple(command)) if command[0] == "aplay" else None
    assert m._linux_default_output() == "hw:CARD=0,DEV=0"

    m._run = lambda command: (
        "1\talsa_output.hdmi\tPipeWire\ts32le\tIDLE\n"
        "2\talsa_output.analog\tPipeWire\ts32le\tRUNNING\n"
    ) if command[0] == "pactl" else None
    assert m._linux_list_available("alsa_output.analog") == ["alsa_output.hdmi"]
    assert m._linux_list_available("capture") == ["alsa_output.analog", "alsa_output.hdmi"]


CASES = {
    "passthrough_nonempty_device": case_passthrough,
    "patches_with_default_output": case_patches_default_output,
    "rejects_capture_device": case_rejects_capture_device,
    "null_when_no_devices": case_null_when_no_devices,
    "preserves_other_fields": case_preserves_other_fields,
    "all_devices_are_capture": case_all_devices_are_capture,
    "saved_used_when_no_default": case_saved_used_when_no_default,
    "system_default_wins_over_saved": case_system_default_wins_over_saved,
    "saved_rejected_when_matches_capture": case_saved_rejected_when_matches_capture,
    "no_default_no_saved_falls_to_first_available": case_no_default_no_saved_falls_to_first_available,
    "saved_match_capture_without_alternatives": case_saved_match_capture_without_alternatives,
    "last_device_purged_when_gone": case_last_device_purged_when_gone,
    "needs_push_decision": case_needs_push,
    "target_playback_device": case_target_device,
    "device_cache_reuse": case_cache_reuse,
    "device_cache_misses": case_cache_misses,
    "config_change_detection": case_config_change,
    "fingerprint_covers_device": case_fingerprint_covers_device,
    "linux_backend_parsing": case_linux_backends,
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
  if output=$(PYTHONDONTWRITEBYTECODE=1 CDSP_MODULE="$CDSP_MODULE" python3 "$helper" "$case_name" 2>&1); then
    assert_pass "$case_name"
  else
    assert_fail "$case_name" "${output:-exited non-zero without a message}"
  fi
}

section 1 "device detection and config resolution"
run_case passthrough_nonempty_device
run_case patches_with_default_output
run_case rejects_capture_device
run_case null_when_no_devices
run_case preserves_other_fields
run_case all_devices_are_capture
run_case target_playback_device

section 2 "fallback order"
run_case saved_used_when_no_default
run_case system_default_wins_over_saved
run_case saved_rejected_when_matches_capture
run_case no_default_no_saved_falls_to_first_available
run_case saved_match_capture_without_alternatives
run_case last_device_purged_when_gone

section 3 "push decision, cache and fingerprint"
run_case needs_push_decision
run_case device_cache_reuse
run_case device_cache_misses
run_case config_change_detection
run_case fingerprint_covers_device

section 4 "Linux backends"
run_case linux_backend_parsing

finish_tests
