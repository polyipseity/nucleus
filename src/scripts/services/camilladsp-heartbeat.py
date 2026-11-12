#!/usr/bin/env python3
"""camilladsp-heartbeat.py: resident playback-device binding loop for CamillaDSP.

This is the only component that pushes the config. It replaces the former bash
loop and its device-selection library. One process holds the websocket
connection and reads the default output device in-process, so a tick spawns
nothing: the bash loop forked about sixteen times per tick, and every
`SwitchAudioSource` spawn cost a TCC attribution through coreaudiod.

Per host behaviour:

- macOS reads CoreAudio through ctypes, so `SwitchAudioSource` and
  `system_profiler` leave the closure entirely.
- Linux reads `aplay -l`, because there is no in-process equivalent without a
  new dependency, and those hosts have no TCC cost. The NixOS config is
  `type: Alsa`, so an ALSA identifier is the only candidate CamillaDSP can
  open: a WirePlumber description or a PulseAudio sink name is not.

The daemon has three stopped states, so a dead endpoint costs nothing:

- endpoint absent: no probe and no push, a cheap retry.
- connected but not Running: push under the doubling backoff.
- Running: skip unless the device, the config, or the live device drifted.

State lives under `$XDG_STATE_HOME/camilladsp`. The device cache is keyed on the
capture device plus a TTL plus the required-device rule, never on the raw probe
string, which flips between ticks.

Toggles come from `~/.local/state/nucleus/config.json`: `camilladsp.heartbeat`
gates the loop, `camilladsp.enable` gates device binding.
"""

from __future__ import annotations

import argparse
import ctypes
import errno
import hashlib
import json
import os
import re
import shutil
import socket
import subprocess
import sys
import time
from pathlib import Path

import yaml

BASE_SLEEP = 5
MAX_SLEEP = 300
# An absent endpoint gets its own cadence: no probe, no push, just a cheap TCP
# connect, so the loop still notices camilladsp starting inside ten seconds.
ABSENT_SLEEP = 10
DEFAULT_TTL = 300
DEFAULT_PORT = 1234

NUCLEUS_CONFIG = Path.home() / ".local/state/nucleus/config.json"
DEFAULT_CONFIG = Path.home() / ".config/camilladsp/configs/config.yml"

# CoreAudio selectors and scopes, as four-character codes.
# Source: CoreAudio.framework/Headers/AudioHardware.h:608-611 and
# AudioHardwareBase.h:203-334. A wrong code returns kAudioHardwareUnknownPropertyError
# ('who?'), which every caller here reads as "no device".
_SYSTEM_OBJECT = 1
_SEL_DEFAULT_OUTPUT = int.from_bytes(b"dOut", "big")
_SEL_DEVICES = int.from_bytes(b"dev#", "big")
_SEL_NAME = int.from_bytes(b"lnam", "big")
_SEL_STREAM_CONFIG = int.from_bytes(b"slay", "big")
_SCOPE_GLOBAL = int.from_bytes(b"glob", "big")
_SCOPE_OUTPUT = int.from_bytes(b"outp", "big")
_ELEMENT_MAIN = 0
_CFSTRING_UTF8 = 0x08000100

_ca = None
_cf = None


class _PropertyAddress(ctypes.Structure):
    _fields_ = [
        ("selector", ctypes.c_uint32),
        ("scope", ctypes.c_uint32),
        ("element", ctypes.c_uint32),
    ]


def _warn(message: str) -> None:
    # The heartbeat log is append-only and read long after the fact, so every
    # line carries its own local time.
    stamp = time.strftime("%Y-%m-%dT%H:%M:%S")
    print(f"{stamp} camilladsp-heartbeat: warning: {message}", file=sys.stderr, flush=True)


def _list_xattrs(path: str) -> list[str]:
    """Extended attribute names on path, read through libc.

    os.listxattr is absent from this interpreter build on both hosts, and a tick
    must not spawn a process, so libc is the only reader available. Any error is
    an empty list: the caller is already reporting a failure.
    """
    try:
        libc = ctypes.CDLL(None)
        libc.listxattr.restype = ctypes.c_ssize_t
        encoded = os.fsencode(path)
        if sys.platform == "darwin":
            libc.listxattr.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_size_t, ctypes.c_int]
            size = libc.listxattr(encoded, None, 0, 0)
        else:
            libc.listxattr.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_size_t]
            size = libc.listxattr(encoded, None, 0)
        if size <= 0:
            return []
        buffer = ctypes.create_string_buffer(size)
        if sys.platform == "darwin":
            written = libc.listxattr(encoded, buffer, size, 0)
        else:
            written = libc.listxattr(encoded, buffer, size)
        if written <= 0:
            return []
        return [name.decode("utf-8", "replace") for name in buffer.raw[:written].split(b"\0") if name]
    except Exception:  # noqa: BLE001 - a diagnostic must never raise over the EDEADLK
        return []


def _provider_state(path: Path) -> str:
    """Compact description of how iCloud provisioned path, for an EDEADLK.

    A File Provider read that has to materialize content can return EDEADLK from
    a launchd context. Nothing else in the log distinguishes that from a stale
    file handle, so the failure carries the evidence needed to tell them apart.
    """
    resolved = os.path.realpath(path)
    parts = [f"path={resolved}"]
    names = _list_xattrs(resolved)
    present = sorted(
        name
        for name in names
        if name.startswith("com.apple.fileprovider") or name == "com.apple.macl"
    )
    parts.append(f"xattrs={','.join(present) or 'none'}")
    placeholder = Path(resolved).parent / f".{Path(resolved).name}.icloud"
    parts.append(f"placeholder={'yes' if placeholder.exists() else 'no'}")
    return " ".join(parts)


def state_dir() -> Path:
    base = os.environ.get("XDG_STATE_HOME") or str(Path.home() / ".local/state")
    return Path(base) / "camilladsp"


def _cache_paths() -> tuple[Path, Path]:
    directory = state_dir()
    return directory / "available-devices.txt", directory / "available-devices.meta"


def _last_device_path() -> Path:
    return state_dir() / "last-device.txt"


def _last_push_path() -> Path:
    return state_dir() / "last-push.txt"


# --- CoreAudio backend -------------------------------------------------------


def _coreaudio() -> tuple[ctypes.CDLL, ctypes.CDLL]:
    """Load CoreAudio and CoreFoundation once, with every signature bound."""
    global _ca, _cf
    if _ca is not None and _cf is not None:
        return _ca, _cf
    if sys.platform != "darwin":
        raise OSError("CoreAudio is only available on macOS")
    ca = ctypes.CDLL("/System/Library/Frameworks/CoreAudio.framework/CoreAudio")
    cf = ctypes.CDLL("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")
    ca.AudioObjectGetPropertyData.argtypes = [
        ctypes.c_uint32,
        ctypes.POINTER(_PropertyAddress),
        ctypes.c_uint32,
        ctypes.c_void_p,
        ctypes.POINTER(ctypes.c_uint32),
        ctypes.c_void_p,
    ]
    ca.AudioObjectGetPropertyData.restype = ctypes.c_int32
    ca.AudioObjectGetPropertyDataSize.argtypes = [
        ctypes.c_uint32,
        ctypes.POINTER(_PropertyAddress),
        ctypes.c_uint32,
        ctypes.c_void_p,
        ctypes.POINTER(ctypes.c_uint32),
    ]
    ca.AudioObjectGetPropertyDataSize.restype = ctypes.c_int32
    cf.CFStringGetCString.argtypes = [
        ctypes.c_void_p,
        ctypes.c_char_p,
        ctypes.c_long,
        ctypes.c_uint32,
    ]
    cf.CFStringGetCString.restype = ctypes.c_bool
    _ca, _cf = ca, cf
    return ca, cf


def _read_u32(object_id: int, selector: int) -> int | None:
    ca, _ = _coreaudio()
    address = _PropertyAddress(selector, _SCOPE_GLOBAL, _ELEMENT_MAIN)
    value = ctypes.c_uint32(0)
    size = ctypes.c_uint32(ctypes.sizeof(value))
    status = ca.AudioObjectGetPropertyData(
        object_id, ctypes.byref(address), 0, None, ctypes.byref(size), ctypes.byref(value)
    )
    if status != 0:
        return None
    return value.value


def _read_cfstring(object_id: int, selector: int, scope: int = _SCOPE_GLOBAL) -> str | None:
    ca, cf = _coreaudio()
    address = _PropertyAddress(selector, scope, _ELEMENT_MAIN)
    ref = ctypes.c_void_p()
    size = ctypes.c_uint32(ctypes.sizeof(ref))
    status = ca.AudioObjectGetPropertyData(
        object_id, ctypes.byref(address), 0, None, ctypes.byref(size), ctypes.byref(ref)
    )
    if status != 0 or not ref:
        return None
    buffer = ctypes.create_string_buffer(1024)
    if not cf.CFStringGetCString(ref, buffer, len(buffer), _CFSTRING_UTF8):
        return None
    return buffer.value.decode("utf-8", "replace")


def _device_ids() -> list[int]:
    ca, _ = _coreaudio()
    address = _PropertyAddress(_SEL_DEVICES, _SCOPE_GLOBAL, _ELEMENT_MAIN)
    size = ctypes.c_uint32(0)
    status = ca.AudioObjectGetPropertyDataSize(
        _SYSTEM_OBJECT, ctypes.byref(address), 0, None, ctypes.byref(size)
    )
    if status != 0 or size.value < ctypes.sizeof(ctypes.c_uint32):
        return []
    count = size.value // ctypes.sizeof(ctypes.c_uint32)
    buffer = (ctypes.c_uint32 * count)()
    status = ca.AudioObjectGetPropertyData(
        _SYSTEM_OBJECT, ctypes.byref(address), 0, None, ctypes.byref(size), buffer
    )
    if status != 0:
        return []
    return list(buffer)


def _has_output(device_id: int) -> bool:
    """True when the device exposes at least one output stream.

    An AudioBufferList starts with its buffer count, which is enough to answer
    the only question asked here: does this device play audio.
    """
    ca, _ = _coreaudio()
    address = _PropertyAddress(_SEL_STREAM_CONFIG, _SCOPE_OUTPUT, _ELEMENT_MAIN)
    size = ctypes.c_uint32(0)
    status = ca.AudioObjectGetPropertyDataSize(
        device_id, ctypes.byref(address), 0, None, ctypes.byref(size)
    )
    if status != 0 or size.value < ctypes.sizeof(ctypes.c_uint32):
        return False
    buffer = ctypes.create_string_buffer(size.value)
    status = ca.AudioObjectGetPropertyData(
        device_id, ctypes.byref(address), 0, None, ctypes.byref(size), buffer
    )
    if status != 0:
        return False
    return ctypes.cast(buffer, ctypes.POINTER(ctypes.c_uint32))[0] > 0


def _macos_default_output() -> str | None:
    device_id = _read_u32(_SYSTEM_OBJECT, _SEL_DEFAULT_OUTPUT)
    if device_id is None:
        return None
    return _read_cfstring(device_id, _SEL_NAME)


def _macos_list_available(capture_device: str) -> list[str] | None:
    device_ids = _device_ids()
    if not device_ids:
        # An empty HAL is a failed enumeration, not an empty device list: treating
        # it as success would silently push a null device.
        return None
    names: list[str] = []
    for device_id in device_ids:
        if not _has_output(device_id):
            continue
        name = _read_cfstring(device_id, _SEL_NAME)
        if name and name != capture_device:
            names.append(name)
    # Locale-independent ordering, matching the previous bash implementation.
    return sorted(names, key=lambda value: value.encode("utf-8"))


# --- Linux backend -----------------------------------------------------------


def _run(command: list[str]) -> str | None:
    # The shell version guarded on `command -v`, so a missing tool is an absent
    # backend rather than a per-tick warning.
    if shutil.which(command[0]) is None:
        return None
    try:
        result = subprocess.run(
            command, capture_output=True, text=True, timeout=10, check=False
        )
    except (OSError, subprocess.SubprocessError) as error:
        _warn(f"{command[0]} failed: {error}")
        return None
    return result.stdout


# `aplay -l` prints one line per playback device:
#   card 0: PCH [HDA Intel PCH], device 0: ALC295 Analog [ALC295 Analog]
_APLAY_DEVICE_LINE = re.compile(
    r"^card (?P<card>\d+): (?P<card_id>\S+) \[[^\]]*\], device (?P<device>\d+):"
)
# aplay capitalizes the id: `card 0: Loopback [Loopback]`.
_ALSA_LOOPBACK_CARD_ID = "loopback"


def _alsa_devices(output: str) -> list[tuple[str, int]]:
    """(card id, device index) for every playback device `aplay -l` reports.

    A loopback card is the capture side of a DSP chain and never a playback
    target, so it is not a candidate.
    """
    devices: list[tuple[str, int]] = []
    for line in output.splitlines():
        match = _APLAY_DEVICE_LINE.match(line)
        if match is None:
            continue
        card_id = match.group("card_id")
        if card_id.lower() == _ALSA_LOOPBACK_CARD_ID:
            continue
        devices.append((card_id, int(match.group("device"))))
    return devices


def _alsa_name(card_id: str, device: int) -> str:
    """CamillaDSP device string. `CARD=` matches the id, never the index."""
    return f"hw:CARD={card_id},DEV={device}"


def _linux_default_output() -> str | None:
    """First device of the first card, or None when `aplay -l` yields nothing.

    ALSA exposes no notion of a default output, so the first card wins. A host
    with several cards pins the intended device in the config, which the
    resolver leaves untouched.
    """
    output = _run(["aplay", "-l"])
    if not output:
        return None
    devices = _alsa_devices(output)
    if not devices:
        return None
    card_id, device = devices[0]
    return _alsa_name(card_id, device)


def _linux_list_available(capture_device: str) -> list[str] | None:
    """Every ALSA playback device except the capture device, byte-sorted."""
    output = _run(["aplay", "-l"])
    if not output:
        return None
    candidates = [
        _alsa_name(card_id, device) for card_id, device in _alsa_devices(output)
    ]
    candidates = [name for name in candidates if name != capture_device]
    if not candidates:
        return None
    # Locale-independent ordering, matching the previous bash implementation.
    return sorted(candidates, key=lambda value: value.encode("utf-8"))


# --- Device detection --------------------------------------------------------


def probe_default_output() -> str | None:
    """Name of the current system default output, or None when unknown."""
    try:
        if sys.platform == "darwin":
            return _macos_default_output()
        return _linux_default_output()
    except OSError as error:
        _warn(f"default output probe failed: {error}")
        return None


def list_available_devices(capture_device: str) -> list[str] | None:
    """Output-capable devices, capture device excluded, sorted by name."""
    try:
        if sys.platform == "darwin":
            return _macos_list_available(capture_device)
        return _linux_list_available(capture_device)
    except OSError as error:
        _warn(f"device enumeration failed: {error}")
        return None


def device_cache_ttl() -> int:
    raw = os.environ.get("CAMILLADSP_DEVICE_CACHE_TTL", str(DEFAULT_TTL))
    try:
        return int(raw)
    except ValueError:
        return DEFAULT_TTL


def list_available_devices_cached(capture_device: str, required_device: str = "") -> list[str] | None:
    """Cached enumeration, re-read whenever the cache cannot answer.

    The key is the capture device plus the TTL plus the required device. The raw
    probe string is deliberately absent: it flips between ticks and turned every
    flip into a full enumeration.
    """
    cache_file, meta_file = _cache_paths()
    ttl = device_cache_ttl()
    if cache_file.is_file() and meta_file.is_file():
        meta = meta_file.read_text().splitlines()
        if len(meta) >= 2:
            cached_capture, cached_at = meta[0], meta[1]
            try:
                age = int(time.time()) - int(cached_at)
            except ValueError:
                age = -1
            cached = [line for line in cache_file.read_text().splitlines() if line]
            reusable = (
                cached_capture == capture_device
                and 0 <= age < ttl
                and (not required_device or required_device in cached)
            )
            if reusable:
                return cached

    devices = list_available_devices(capture_device)
    if devices is None:
        return None
    state_dir().mkdir(parents=True, exist_ok=True)
    meta_file.write_text(f"{capture_device}\n{int(time.time())}\n")
    cache_file.write_text("".join(f"{name}\n" for name in devices))
    return devices


def invalidate_device_cache() -> None:
    for path in _cache_paths():
        try:
            path.unlink()
        except FileNotFoundError:
            continue


def detect_first_available(capture_device: str) -> str | None:
    """First available playback device, never the capture device.

    The backend already excludes capture, and this repeats the check because a
    backend that regressed would otherwise open an audio loop.
    """
    devices = list_available_devices_cached(capture_device)
    if not devices:
        return None
    for name in devices:
        if name != capture_device:
            return name
    return None


def save_last_device(device: str) -> None:
    if not device:
        return
    state_dir().mkdir(parents=True, exist_ok=True)
    _last_device_path().write_text(device)


def load_last_device() -> str | None:
    path = _last_device_path()
    if not path.is_file():
        return None
    value = path.read_text().strip()
    return value or None


def clear_last_device() -> None:
    try:
        _last_device_path().unlink()
    except FileNotFoundError:
        return


# --- Config resolution -------------------------------------------------------


def _load_config(config_file: Path) -> dict:
    return yaml.safe_load(config_file.read_text()) or {}


def _devices(config: dict) -> dict:
    value = config.get("devices")
    return value if isinstance(value, dict) else {}


def _device_of(config: dict, direction: str) -> str:
    section = _devices(config).get(direction)
    if not isinstance(section, dict):
        return ""
    value = section.get("device")
    return value if isinstance(value, str) else ""


def _dump_config(config: dict) -> str:
    return yaml.safe_dump(config, sort_keys=False, allow_unicode=True)


def _with_device(config: dict, device: str) -> str:
    devices = _devices(config)
    playback = devices.get("playback")
    if not isinstance(playback, dict):
        playback = {}
        devices["playback"] = playback
    playback["device"] = device
    config["devices"] = devices
    return _dump_config(config)


def resolve_playback_device(config_file: Path) -> str:
    """Config text with the playback device resolved when it is null.

    Resolution order: system default output, last saved device validated against
    the available list, first available device. The capture device is never
    chosen, because playback and capture on one device is an audio loop.
    """
    original = config_file.read_text()
    config = _load_config(config_file)
    existing = _device_of(config, "playback")
    if existing:
        return original
    capture = _device_of(config, "capture")

    probe = probe_default_output() or ""
    detected = "" if probe == capture else probe

    if not detected:
        saved = load_last_device()
        if saved and saved != capture:
            devices = list_available_devices_cached(capture, saved)
            if devices is None:
                detected = saved
            elif saved in devices:
                detected = saved
            else:
                clear_last_device()

    if not detected:
        detected = detect_first_available(capture) or ""

    if not detected:
        return original
    return _with_device(config, detected)


def target_playback_device(config_file: Path) -> str:
    """The device detection would select right now, or an empty string."""
    if not config_file.is_file():
        return ""
    try:
        config = yaml.safe_load(resolve_playback_device(config_file)) or {}
    except yaml.YAMLError as error:
        _warn(f"resolved config is not valid YAML: {error}")
        return ""
    return _device_of(config, "playback")


def probe(config_file: Path) -> int:
    """Print what device detection sees, and exit non-zero when it binds nothing.

    Detection failures are silent in the loop: a successful tick logs nothing and
    a failed one logs a traceback, so this is the only way to see the values the
    resolver works from.
    """
    capture = ""
    if config_file.is_file():
        try:
            capture = _device_of(_load_config(config_file), "capture")
        except (OSError, yaml.YAMLError) as error:
            _warn(f"cannot read {config_file}: {error}")
            return 1
    default = probe_default_output() or ""
    available = list_available_devices(capture) or []
    target = target_playback_device(config_file) if config_file.is_file() else ""
    print(f"platform={sys.platform}")
    print(f"config={config_file}")
    print(f"capture={capture}")
    print(f"default_output={default}")
    print(f"available={','.join(available)}")
    print(f"target={target}")
    if not target:
        _warn("probe found no playback device to bind")
        return 1
    return 0


def needs_push(state: str, live_device: str, target_device: str, config_changed: bool) -> bool:
    """Pure skip decision, mirroring the previous bash implementation.

    A null target is skipped while Running, because the resolver falls back to
    the first available device and a null device is never actually pushed.
    """
    if state == "Running" and not target_device:
        return False
    if state == "Running" and live_device and live_device == target_device and not config_changed:
        return False
    return True


def config_fingerprint(config_file: Path, target_device: str) -> str:
    """Fingerprint over the config bytes and the resolved device.

    The device is part of it because the config stores a null playback device, so
    a device change would otherwise look like no change.
    """
    digest = hashlib.sha256()
    digest.update(config_file.read_bytes())
    digest.update(b"\n--playback-device--\n")
    digest.update(target_device.encode("utf-8"))
    return digest.hexdigest()


def config_changed(config_file: Path, target_device: str) -> bool:
    path = _last_push_path()
    if not path.is_file():
        return True
    return path.read_text().strip() != config_fingerprint(config_file, target_device)


def record_push(fingerprint: str) -> None:
    if not fingerprint:
        return
    state_dir().mkdir(parents=True, exist_ok=True)
    _last_push_path().write_text(fingerprint)


# --- Websocket client --------------------------------------------------------


class CamillaClient:
    """One long-lived websocket connection, reconnected on demand."""

    def __init__(self, port: int) -> None:
        self.port = port
        self._socket = None

    @property
    def url(self) -> str:
        return f"ws://127.0.0.1:{self.port}"

    def endpoint_up(self) -> bool:
        """Cheap TCP check, so an absent endpoint costs no probe and no push."""
        try:
            with socket.create_connection(("127.0.0.1", self.port), timeout=1):
                return True
        except OSError:
            return False

    def reset(self) -> None:
        connection = self._socket
        self._socket = None
        if connection is None:
            return
        try:
            connection.close()
        except Exception as error:  # noqa: BLE001 - closing a broken socket
            _warn(f"closing the stale connection failed: {error}")

    def _connect(self):
        # Imported here so the decision functions stay importable and testable
        # without the websocket client installed.
        from websockets.sync.client import connect

        return connect(self.url, open_timeout=3, close_timeout=1, max_size=None)

    def request(self, payload: dict) -> dict:
        if self._socket is None:
            self._socket = self._connect()
        self._socket.send(json.dumps(payload))
        raw = self._socket.recv(timeout=10)
        if isinstance(raw, bytes):
            raw = raw.decode("utf-8")
        return json.loads(raw)


def _state_of(response: dict) -> str:
    section = response.get("GetState")
    if not isinstance(section, dict):
        return ""
    value = section.get("value")
    return value if isinstance(value, str) else ""


def _live_device(client: CamillaClient) -> str:
    section = client.request({"GetConfig": None}).get("GetConfig")
    if not isinstance(section, dict):
        return ""
    text = section.get("value")
    if not isinstance(text, str):
        return ""
    try:
        config = yaml.safe_load(text) or {}
    except yaml.YAMLError:
        return ""
    return _device_of(config, "playback")


def _set_config_result(response: dict) -> str:
    section = response.get("SetConfig")
    if not isinstance(section, dict):
        return ""
    value = section.get("result")
    return value if isinstance(value, str) else ""


def push_config(client: CamillaClient, config_file: Path, target_device: str) -> bool:
    """Resolve and push the config, returning whether camilladsp accepted it."""
    if target_device:
        text = _with_device(_load_config(config_file), target_device)
    else:
        text = resolve_playback_device(config_file)

    response = client.request({"SetConfig": text})
    if _set_config_result(response) != "Ok":
        # Rejected rather than unreachable, so the resolved device is probably
        # gone even though the cache still lists it.
        invalidate_device_cache()
        return False

    pushed = ""
    try:
        pushed = _device_of(yaml.safe_load(text) or {}, "playback")
    except yaml.YAMLError as error:
        _warn(f"pushed config is not valid YAML: {error}")
    save_last_device(pushed)
    record_push(config_fingerprint(config_file, pushed))
    return True


# --- Loop --------------------------------------------------------------------


def read_toggles() -> tuple[bool, bool]:
    """(heartbeat, binding) from the nucleus runtime config, defaulting to on."""
    if not NUCLEUS_CONFIG.is_file():
        return True, True
    try:
        data = json.loads(NUCLEUS_CONFIG.read_text())
    except (OSError, json.JSONDecodeError) as error:
        _warn(f"cannot read {NUCLEUS_CONFIG}: {error}")
        return True, True
    node = data.get("camilladsp")
    if not isinstance(node, dict):
        return True, True
    heartbeat = node.get("heartbeat")
    binding = node.get("enable")
    # `or` would collapse an explicit false, so compare against None.
    return (True if heartbeat is None else bool(heartbeat)), (
        True if binding is None else bool(binding)
    )


def run(port: int, config_file: Path) -> int:
    client = CamillaClient(port)
    sleep_seconds = BASE_SLEEP

    while True:
        heartbeat, binding = read_toggles()
        if not heartbeat or not binding:
            # The loop keeps running so the websocket API stays up for
            # camillagui, but nothing opens a capture device.
            time.sleep(BASE_SLEEP)
            continue

        if not client.endpoint_up():
            client.reset()
            sleep_seconds = BASE_SLEEP
            time.sleep(ABSENT_SLEEP)
            continue

        success = False
        try:
            state = _state_of(client.request({"GetState": None}))
            live = _live_device(client) if state == "Running" else ""
            target = target_playback_device(config_file) if config_file.is_file() else ""
            changed = config_file.is_file() and config_changed(config_file, target)
            if needs_push(state, live, target, changed):
                success = push_config(client, config_file, target)
            else:
                success = True
        except OSError as error:
            detail = f" [{_provider_state(config_file)}]" if error.errno == errno.EDEADLK else ""
            _warn(f"tick failed: {error}{detail}")
            client.reset()
        except (ValueError, json.JSONDecodeError) as error:
            _warn(f"tick failed: {error}")
            client.reset()
        except Exception as error:  # noqa: BLE001 - websockets raises its own types
            _warn(f"tick failed: {error}")
            client.reset()

        sleep_seconds = BASE_SLEEP if success else min(sleep_seconds * 2, MAX_SLEEP)
        time.sleep(sleep_seconds)


def main() -> int:
    parser = argparse.ArgumentParser(description="CamillaDSP device binding heartbeat")
    parser.add_argument("--port", type=int, default=DEFAULT_PORT)
    parser.add_argument("--config", type=Path, default=DEFAULT_CONFIG)
    parser.add_argument(
        "--probe",
        action="store_true",
        help="print what device detection sees and exit (0 bound, 1 nothing)",
    )
    arguments = parser.parse_args()
    if arguments.probe:
        return probe(arguments.config)
    return run(arguments.port, arguments.config)


if __name__ == "__main__":
    sys.exit(main())
