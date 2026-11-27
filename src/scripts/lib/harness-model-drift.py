#!/usr/bin/env python3
"""Validate harness model payloads against the LiteLLM gateway and its registries.

Run from either check twin with --repo-root. The validator reads B1's alias
table, B2's merge registry, the B3 payloads, and the prompt-capability matrix,
then proves the merge tool can seed a temporary HOME and pass --check against
it. It also checks the two method-1 tracked sources already carry their owned
slots, so a symlink target cannot depend on a write the merge tool refuses.
It never writes to the repository.
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import subprocess
import sys
import tempfile
import tomllib
from pathlib import Path
from types import ModuleType
from typing import Any

try:
    import yaml
except Exception as exc:  # pragma: no cover - runtime env dependency
    print(f"harness-model-drift: cannot import yaml: {exc}", file=sys.stderr)
    raise SystemExit(2) from exc


LIMIT_KEYS = ("maxInputTokens", "maxOutputTokens")

METHOD1_TRACKED_SOURCES = {
    "claude": "src/users/default/claude/settings.json",
    "opencode": "src/users/default/opencode/opencode.jsonc",
}


class DriftError(ValueError):
    """Raised for a registry or payload shape the validator cannot trust."""


def _report(message: str) -> None:
    print(f"harness-model-drift: {message}", file=sys.stderr)


def _load_json(path: Path, label: str) -> Any:
    try:
        raw = path.read_text(encoding="utf-8")
    except OSError as exc:
        raise DriftError(f"cannot read {label} {path}: {exc}") from exc
    try:
        return json.loads(raw)
    except json.JSONDecodeError as exc:
        raise DriftError(f"invalid JSON in {label} {path}: {exc}") from exc


def _load_yaml(path: Path) -> Any:
    try:
        raw = path.read_text(encoding="utf-8")
    except OSError as exc:
        raise DriftError(f"cannot read payload {path}: {exc}") from exc
    try:
        return yaml.safe_load(raw)
    except yaml.YAMLError as exc:
        raise DriftError(f"invalid YAML in payload {path}: {exc}") from exc


def _load_toml(path: Path) -> Any:
    try:
        raw = path.read_text(encoding="utf-8")
    except OSError as exc:
        raise DriftError(f"cannot read payload {path}: {exc}") from exc
    try:
        return tomllib.loads(raw)
    except tomllib.TOMLDecodeError as exc:
        raise DriftError(f"invalid TOML in payload {path}: {exc}") from exc


def _load_payload(path: Path, fmt: str) -> Any:
    if fmt == "yaml":
        return _load_yaml(path)
    if fmt == "toml":
        return _load_toml(path)
    return _load_json(path, "payload")


def _import_alias_module(root: Path) -> ModuleType:
    path = root / "src/scripts/lib/litellm-aliases.py"
    spec = importlib.util.spec_from_file_location("nucleus_litellm_aliases", path)
    if spec is None or spec.loader is None:
        raise DriftError(f"cannot import B1 alias module from {path}")
    module = importlib.util.module_from_spec(spec)
    # WHY: the check is read-only, and importing from the repo tree would
    # otherwise write a __pycache__ beside the B1 module.
    previous = sys.dont_write_bytecode
    sys.dont_write_bytecode = True
    try:
        spec.loader.exec_module(module)
    except Exception as exc:
        raise DriftError(f"cannot load B1 alias module from {path}: {exc}") from exc
    finally:
        sys.dont_write_bytecode = previous
    return module


def _import_merge_module(root: Path) -> ModuleType:
    path = root / "src/scripts/agents/merge-harness-models.py"
    spec = importlib.util.spec_from_file_location("nucleus_merge_harness_models", path)
    if spec is None or spec.loader is None:
        raise DriftError(f"cannot import merge module from {path}")
    module = importlib.util.module_from_spec(spec)
    # WHY: dataclass in the merge module resolves annotations through
    # sys.modules[__name__], so an unregistered module fails before any check.
    sys.modules[spec.name] = module
    previous = sys.dont_write_bytecode
    sys.dont_write_bytecode = True
    try:
        spec.loader.exec_module(module)
    except Exception as exc:
        sys.modules.pop(spec.name, None)
        raise DriftError(f"cannot load merge module from {path}: {exc}") from exc
    finally:
        sys.dont_write_bytecode = previous
    return module


def _alias_table(root: Path) -> dict[str, dict[str, int | None]]:
    """Use B1's own parser so this check cannot drift from its limit rule."""
    module = _import_alias_module(root)
    config = root / "src/modules/configs/litellm/config.yml"
    try:
        return module.build_alias_table(module._load_yaml(config))
    except Exception as exc:
        raise DriftError(f"cannot derive B1 alias table: {exc}") from exc


def _registry_entries(root: Path) -> list[dict[str, Any]]:
    registry = _load_json(root / "src/modules/configs/harness-models.json", "registry")
    if not isinstance(registry, dict) or not isinstance(registry.get("harnesses"), list):
        raise DriftError("registry must be an object with a harnesses list")
    entries: list[dict[str, Any]] = []
    for index, entry in enumerate(registry["harnesses"]):
        if not isinstance(entry, dict) or not isinstance(entry.get("harness"), str):
            raise DriftError(f"registry.harnesses[{index}] must name a harness")
        entries.append(entry)
    return entries


def _payload_path(root: Path, entry: dict[str, Any], label: str) -> Path:
    raw = entry.get("payload")
    if not isinstance(raw, str) or not raw.strip():
        raise DriftError(f"{label}: payload must be one canonical repo-relative path")
    path = Path(raw)
    if path.is_absolute():
        raise DriftError(f"{label}: payload path must be repo-relative: {raw}")
    return (root / path).resolve()


def _model_map(payload: Any, label: str) -> dict[str, Any] | None:
    if not isinstance(payload, dict):
        raise DriftError(f"{label}: payload must be a mapping")
    models = payload.get("models")
    if models is None:
        return None
    if isinstance(models, dict):
        return models
    if isinstance(models, list):
        result: dict[str, Any] = {}
        for item in models:
            if not isinstance(item, dict) or not isinstance(item.get("id"), str):
                raise DriftError(f"{label}: model list entries need a string id")
            result[item["id"]] = item
        return result
    raise DriftError(f"{label}: models must be a mapping or a list")


def _check_payload(
    root: Path,
    entry: dict[str, Any],
    aliases: dict[str, dict[str, int | None]],
    errors: list[str],
) -> None:
    label = str(entry["harness"])
    try:
        payload = _load_payload(_payload_path(root, entry, label), str(entry.get("format")))
        models = _model_map(payload, label)
    except DriftError as exc:
        errors.append(str(exc))
        return

    if models is None:
        if label == "claude":
            _check_env_pin(payload, aliases, label, errors)
        elif label == "codex":
            _check_codex_pin(payload, entry.get("slot"), aliases, label, errors)
        return

    missing = sorted(set(aliases) - set(models))
    extra = sorted(set(models) - set(aliases))
    if missing:
        errors.append(f"{label}: missing aliases: {', '.join(missing)}")
    if extra:
        errors.append(f"{label}: extra aliases: {', '.join(extra)}")

    for alias in sorted(set(aliases) & set(models)):
        limits = models[alias]
        if not isinstance(limits, dict):
            errors.append(f"{label}: {alias}: model limits must be a mapping")
            continue
        for key in LIMIT_KEYS:
            expected = aliases[alias][key]
            if key not in limits:
                if expected is not None:
                    errors.append(f"{label}: {alias}: {key} missing in payload, B1 declares {expected}")
                continue
            if expected is None:
                errors.append(f"{label}: {alias}: {key} declared in payload but null in B1")
                continue
            if limits[key] != expected:
                errors.append(f"{label}: {alias}: {key} expected {expected}, got {limits[key]}")


def _assert_alias_pin(
    model: Any,
    aliases: dict[str, dict[str, int | None]],
    label: str,
    source: str,
    errors: list[str],
) -> None:
    if not isinstance(model, str) or not model:
        errors.append(f"{label}: pinned model is missing from {source}")
        return
    if model not in aliases:
        errors.append(f"{label}: pinned model '{model}' is not a B1 alias")


def _check_env_pin(
    payload: Any,
    aliases: dict[str, dict[str, int | None]],
    label: str,
    errors: list[str],
) -> None:
    if not isinstance(payload, dict):
        errors.append(f"{label}: env payload must be a mapping")
        return
    # WHY: Claude's B3 payload pins one model through this env key instead of
    # carrying a model map, so a stale id needs the same B1 check as Codex.
    _assert_alias_pin(payload.get("ANTHROPIC_MODEL"), aliases, label, "ANTHROPIC_MODEL", errors)


def _check_codex_pin(
    payload: Any,
    slot: Any,
    aliases: dict[str, dict[str, int | None]],
    label: str,
    errors: list[str],
) -> None:
    if not isinstance(payload, dict):
        errors.append(f"{label}: TOML payload must be a mapping")
        return
    table = slot.get("table") if isinstance(slot, dict) else None
    if not isinstance(table, str):
        errors.append(f"{label}: registry slot has no TOML table")
        return
    current: Any = payload
    for part in table.split("."):
        current = current.get(part) if isinstance(current, dict) else None
    model = current.get("model") if isinstance(current, dict) else None
    _assert_alias_pin(model, aliases, label, f"[{table}]", errors)


def _check_vscode_hosts(root: Path, entries: list[dict[str, Any]], errors: list[str]) -> None:
    for entry in entries:
        if entry.get("harness") != "vscode":
            continue
        slot = entry.get("slot")
        if not isinstance(slot, dict) or slot.get("kind") != "named-array-item":
            errors.append("vscode: registry slot must be named-array-item")
            return
        match_key, match_value = slot.get("matchKey"), slot.get("matchValue")
        paths = entry.get("path")
        if not isinstance(paths, dict) or not isinstance(match_key, str) or not isinstance(match_value, str):
            errors.append("vscode: registry needs a host path map and a named item")
            return
        try:
            canonical_path = _payload_path(root, entry, "vscode")
            canonical = _load_payload(canonical_path, str(entry.get("format")))
            if not isinstance(canonical, dict):
                raise DriftError("vscode: canonical payload must be an object")
        except DriftError as exc:
            errors.append(str(exc))
            return

        paths_seen: dict[str, str] = {}
        for host in sorted(paths):
            live_path = str(paths[host])
            if live_path in paths_seen:
                errors.append(f"vscode:{host}: duplicate live path {live_path}, already used by {paths_seen[live_path]}")
                continue
            paths_seen[live_path] = host
            live_name = Path(live_path).name
            if live_name != "chatLanguageModels.json":
                errors.append(
                    f"vscode:{host}: registry path basename must be chatLanguageModels.json, got {live_name}"
                )
                continue
            # WHY: VS Code reads one unsuffixed live file, while drift validation
            # compares against the host-keyed payloads kept in the repo tree.
            source = canonical_path.parent / f"chatLanguageModels.{host}.json"
            try:
                host_data = _load_json(source, "VS Code host payload")
                if not isinstance(host_data, list):
                    raise DriftError(f"vscode:{host}: host payload must be an array")
                matched = [
                    item for item in host_data
                    if isinstance(item, dict) and item.get(match_key) == match_value
                ]
                if len(matched) != 1:
                    raise DriftError(
                        f"vscode:{host}: expected one {match_key}={match_value} entry, found {len(matched)}"
                    )
                if matched[0] != canonical:
                    errors.append(f"vscode:{host}: LiteLLM entry differs from canonical payload")
            except DriftError as exc:
                errors.append(str(exc))


def _check_registry_parity(root: Path, entries: list[dict[str, Any]], errors: list[str]) -> None:
    capabilities = _load_json(root / "src/modules/configs/harness-capabilities.json", "capabilities")
    if not isinstance(capabilities, dict) or not isinstance(capabilities.get("harnesses"), dict):
        raise DriftError("capabilities must be an object with a harnesses map")
    model_ids = {str(entry["harness"]) for entry in entries}
    capability_ids = capabilities["harnesses"]

    for harness in sorted(model_ids):
        if harness not in capability_ids:
            errors.append(f"registry: model harness '{harness}' missing from capabilities")
    for harness, value in sorted(capability_ids.items()):
        commands = value.get("commands", []) if isinstance(value, dict) else []
        if commands and harness not in model_ids:
            errors.append(f"capabilities: harness '{harness}' declares prompt commands but has no model payload")


def _check_tracked_sources(root: Path, errors: list[str]) -> None:
    """Prove the method-1 sources carry the slots a symlink cannot receive."""
    merge = _import_merge_module(root)
    registry = root / "src/modules/configs/harness-models.json"
    try:
        entries = {entry.harness: entry for entry in merge._load_registry(registry)}
    except merge.MergeError as exc:
        errors.append(f"cannot load merge registry for tracked sources: {exc}")
        return

    for harness, relative in sorted(METHOD1_TRACKED_SOURCES.items()):
        entry = entries.get(harness)
        if entry is None:
            errors.append(f"{harness}: no merge registry entry for tracked source")
            continue
        source = (root / relative).resolve()
        try:
            text = source.read_text(encoding="utf-8")
            current = merge._extract_slot(entry, source, text)
            payload = merge._payload_for_target(entry, root, harness)
            if merge._normalize_for_compare(entry, current) != merge._normalize_for_compare(entry, payload):
                errors.append(f"{harness}: tracked source {relative} slot is missing or stale")
        except (OSError, merge.MergeError, KeyError, TypeError, ValueError) as exc:
            errors.append(f"{harness}: tracked source {relative} slot is missing or stale: {exc}")


def _run_merge(root: Path, home: Path, check: bool) -> subprocess.CompletedProcess[str]:
    command = [
        sys.executable,
        str(root / "src/scripts/agents/merge-harness-models.py"),
        "--repo-root",
        str(root),
        "--home",
        str(home),
    ]
    if check:
        command.append("--check")
    return subprocess.run(command, capture_output=True, text=True, check=False)


def _check_merge(root: Path, errors: list[str]) -> None:
    label = "merge"
    with tempfile.TemporaryDirectory(prefix="harness-model-drift-") as tmp:
        home = Path(tmp) / "home"
        home.mkdir()
        seed = _run_merge(root, home, check=False)
        check = _run_merge(root, home, check=True)
        detail = [
            *[line for line in seed.stdout.splitlines() if line],
            *[line for line in seed.stderr.splitlines() if line],
            *[line for line in check.stdout.splitlines() if line],
            *[line for line in check.stderr.splitlines() if line],
        ]
        if seed.returncode != 0:
            errors.append(f"{label}: merge --seed failed: {seed.stderr.strip()}")
            errors.extend(f"  merge: {line}" for line in detail)
        if check.returncode != 0:
            errors.append(f"{label}: merge --check failed: {check.stderr.strip()}")
            errors.extend(f"  merge: {line}" for line in detail)


def validate(root: Path) -> list[str]:
    errors: list[str] = []
    try:
        aliases = _alias_table(root)
        entries = _registry_entries(root)
        _check_registry_parity(root, entries, errors)
    except DriftError as exc:
        return [str(exc)]

    for entry in entries:
        _check_payload(root, entry, aliases, errors)
    _check_vscode_hosts(root, entries, errors)
    _check_tracked_sources(root, errors)
    _check_merge(root, errors)
    return errors


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--repo-root",
        type=Path,
        required=True,
        help="Repository root whose payloads and registries are validated.",
    )
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    root = args.repo_root.resolve()
    try:
        errors = validate(root)
    except DriftError as exc:
        _report(str(exc))
        return 1
    for error in errors:
        _report(error)
    if errors:
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
