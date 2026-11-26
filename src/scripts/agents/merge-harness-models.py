#!/usr/bin/env python3
"""Merge LiteLLM model slots into harness config files.

The tool is registry-driven: src/modules/configs/harness-models.json describes
each harness, the target config path, the owned slot, and the repo-relative
payload file that holds the desired slot value.

Contract (plan B2):
- Only the owned slot's value is replaced. Everything outside it is
  byte-identical, including comments, key order, and trailing newlines.
- JSON/JSONC: replace the key's value span; JSONC comments outside the value
  survive because only the value span is rewritten.
- YAML: custom_providers is a list keyed by name; replace the litellm item,
  keep every other item verbatim.
- TOML: replace the [model_providers.litellm] table and the top-level
  model_provider scalar by surgical text splice. Refuse rather than
  reformatting unrelated bytes.
- Missing target file is created with only the owned slot.
- Corrupt/unparseable file is a hard error naming file and parse position;
  never replaced.
- --check writes nothing, compares live slot to payload, exits non-zero
  listing each drifting harness.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any

try:
    import yaml  # type: ignore[import-untyped]
except Exception as exc:  # pragma: no cover - runtime env dependency
    print(f"merge-harness-models: cannot import yaml: {exc}", file=sys.stderr)
    raise SystemExit(2) from exc

try:
    import tomllib
except Exception:  # pragma: no cover - py<3.11 fallback
    tomllib = None  # type: ignore[assignment]


class MergeError(ValueError):
    """A harness merge/check failed safely."""


@dataclass(frozen=True)
class HarnessEntry:
    harness: str
    path: str | dict[str, str]
    fmt: str
    slot: dict[str, Any]
    payload: str | dict[str, str]


def _repo_root() -> Path:
    return Path(__file__).resolve().parents[3]


def _default_registry() -> Path:
    # check-suppress:config-method: method 4 (runtime direct read) -- registry is data read by merge-harness-models.py at runtime.
    return _repo_root() / "src/modules/configs/harness-models.json"


def _eprint(msg: str) -> None:
    print(f"merge-harness-models: {msg}", file=sys.stderr)


def _load_json_file(path: Path, label: str) -> Any:
    try:
        raw = path.read_text(encoding="utf-8")
    except FileNotFoundError as exc:
        raise MergeError(f"{label} not found: {path}") from exc
    except OSError as exc:
        raise MergeError(f"cannot read {label} {path}: {exc}") from exc
    try:
        return json.loads(raw)
    except json.JSONDecodeError as exc:
        raise MergeError(
            f"invalid JSON in {label} {path}: line {exc.lineno} column {exc.colno}: {exc.msg}"
        ) from exc


def _load_registry(path: Path) -> list[HarnessEntry]:
    data = _load_json_file(path, "registry")
    if not isinstance(data, dict):
        raise MergeError(f"registry must be a top-level object: {path}")
    entries = data.get("harnesses")
    if not isinstance(entries, list):
        raise MergeError(f"registry.harnesses must be a list: {path}")
    out: list[HarnessEntry] = []
    for i, entry in enumerate(entries):
        if not isinstance(entry, dict):
            raise MergeError(f"registry.harnesses[{i}] must be an object")
        harness = entry.get("harness")
        target_path = entry.get("path")
        fmt = entry.get("format")
        slot = entry.get("slot")
        payload = entry.get("payload")
        if not isinstance(harness, str) or not harness.strip():
            raise MergeError(f"registry.harnesses[{i}] missing harness id")
        if not isinstance(target_path, (str, dict)):
            raise MergeError(f"registry.harnesses[{i}] path must be string or host map")
        if isinstance(target_path, dict):
            for k, v in target_path.items():
                if not isinstance(k, str) or not isinstance(v, str):
                    raise MergeError(
                        f"registry.harnesses[{i}] path map must be string:string"
                    )
        if fmt not in {"json", "jsonc", "yaml", "toml"}:
            raise MergeError(
                f"registry.harnesses[{i}] format must be json|jsonc|yaml|toml"
            )
        if not isinstance(slot, dict):
            raise MergeError(f"registry.harnesses[{i}] slot must be an object")
        if isinstance(payload, str):
            if not payload.strip():
                raise MergeError(f"registry.harnesses[{i}] missing payload")
            payload_norm: str | dict[str, str] = payload.strip()
        elif isinstance(payload, dict):
            if not payload or not all(isinstance(k, str) and isinstance(v, str) and v.strip() for k, v in payload.items()):
                raise MergeError(f"registry.harnesses[{i}] payload map must be string:string")
            payload_norm = {k: v.strip() for k, v in payload.items()}
        else:
            raise MergeError(f"registry.harnesses[{i}] payload must be string or host map")
        out.append(
            HarnessEntry(
                harness=harness.strip(),
                path=target_path,
                fmt=fmt,
                slot=slot,
                payload=payload_norm,
            )
        )
    return out


def _resolve_repo_path(repo_root: Path, raw: str) -> Path:
    p = Path(raw)
    if p.is_absolute():
        return p
    return (repo_root / p).resolve()


def _resolve_home_path(raw: str, home: Path) -> Path:
    if raw.startswith("~/"):
        return (home / raw[2:]).resolve()
    p = Path(raw)
    if p.is_absolute():
        return p
    return (home / p).resolve()


def _json_text(value: Any) -> str:
    return json.dumps(value, indent=2, ensure_ascii=False) + "\n"


def _json_compact(value: Any) -> str:
    return json.dumps(value, separators=(",", ":"), ensure_ascii=False)


def _payload_value(entry: HarnessEntry, repo_root: Path) -> Any:
    payload_path = _resolve_repo_path(repo_root, entry.payload)
    raw = payload_path.read_text(encoding="utf-8")
    try:
        if entry.fmt == "yaml":
            value = yaml.safe_load(raw)
        elif entry.fmt == "toml":
            if tomllib is None:
                raise MergeError(f"tomllib unavailable; cannot read TOML payload {payload_path}")
            try:
                value = tomllib.loads(raw)
            except Exception as exc:
                raise MergeError(f"invalid TOML in payload {payload_path}: {exc}") from exc
        else:
            value = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise MergeError(
            f"invalid JSON in payload {payload_path}: line {exc.lineno} column {exc.colno}: {exc.msg}"
        ) from exc
    except yaml.YAMLError as exc:
        raise MergeError(f"invalid YAML in payload {payload_path}: {exc}") from exc
    if entry.fmt == "toml" and entry.slot.get("kind") == "toml-provider-table":
        top_key = entry.slot.get("topLevelKey")
        table = entry.slot.get("table")
        normalized: dict[str, Any] = {}
        if isinstance(top_key, str) and top_key in value:
            normalized[top_key] = value[top_key]
        if isinstance(table, str):
            current: Any = value
            found = True
            for part in table.split("."):
                if not isinstance(current, dict) or part not in current:
                    found = False
                    break
                current = current[part]
            if found and isinstance(current, dict):
                normalized[table] = current
        value = normalized
    return value


# ---- JSON/JSONC value-span replacement ------------------------------------

def _skip_ws(text: str, i: int) -> int:
    while i < len(text) and text[i] in " \t\r\n":
        i += 1
    return i


def _skip_string(text: str, i: int) -> int:
    assert text[i] == '"'
    i += 1
    while i < len(text):
        ch = text[i]
        if ch == "\\":
            i += 2
            continue
        i += 1
        if ch == '"':
            return i
    raise MergeError("unterminated JSON string")


def _skip_line_comment(text: str, i: int) -> int:
    j = text.find("\n", i + 2)
    return len(text) if j < 0 else j + 1


def _skip_block_comment(text: str, i: int) -> int:
    j = text.find("*/", i + 2)
    if j < 0:
        raise MergeError("unterminated block comment")
    return j + 2


def _skip_ws_comments(text: str, i: int, allow_comments: bool) -> int:
    while i < len(text):
        j = _skip_ws(text, i)
        if allow_comments and text.startswith("//", j):
            i = _skip_line_comment(text, j)
            continue
        if allow_comments and text.startswith("/*", j):
            i = _skip_block_comment(text, j)
            continue
        return j
    return len(text)


def _consume_json_value(text: str, i: int, allow_comments: bool, path: Path) -> int:
    i = _skip_ws_comments(text, i, allow_comments)
    if i >= len(text):
        raise MergeError(f"unexpected end of JSON in {path}")
    ch = text[i]
    if ch == '"':
        return _skip_string(text, i)
    if ch in "-0123456789":
        m = re.match(r"-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?", text[i:])
        if not m:
            raise MergeError(f"invalid number in {path} at offset {i}")
        return i + m.end()
    if text.startswith("true", i):
        return i + 4
    if text.startswith("false", i):
        return i + 5
    if text.startswith("null", i):
        return i + 4
    if ch == "[":
        return _consume_json_array(text, i, allow_comments, path)
    if ch == "{":
        return _consume_json_object(text, i, allow_comments, path)
    line = text.count("\n", 0, i) + 1
    col = i - (text.rfind("\n", 0, i) + 1) + 1
    raise MergeError(f"invalid JSON token in {path}: line {line} column {col}")


def _consume_json_array(text: str, i: int, allow_comments: bool, path: Path) -> int:
    assert text[i] == "["
    i = _skip_ws_comments(text, i + 1, allow_comments)
    if i < len(text) and text[i] == "]":
        return i + 1
    while i < len(text):
        i = _consume_json_value(text, i, allow_comments, path)
        i = _skip_ws_comments(text, i, allow_comments)
        if i < len(text) and text[i] == ",":
            i = _skip_ws_comments(text, i + 1, allow_comments)
            if allow_comments and i < len(text) and text[i] == "]":
                return i + 1
            continue
        if i < len(text) and text[i] == "]":
            return i + 1
        line = text.count("\n", 0, i) + 1
        col = i - (text.rfind("\n", 0, i) + 1) + 1
        raise MergeError(f"invalid JSON array in {path}: line {line} column {col}")
    raise MergeError(f"unterminated JSON array in {path}")


def _consume_json_object(text: str, i: int, allow_comments: bool, path: Path) -> int:
    assert text[i] == "{"
    i = _skip_ws_comments(text, i + 1, allow_comments)
    if i < len(text) and text[i] == "}":
        return i + 1
    while i < len(text):
        if text[i] != '"':
            line = text.count("\n", 0, i) + 1
            col = i - (text.rfind("\n", 0, i) + 1) + 1
            raise MergeError(f"expected object key in {path}: line {line} column {col}")
        i = _skip_string(text, i)
        i = _skip_ws_comments(text, i, allow_comments)
        if i >= len(text) or text[i] != ":":
            line = text.count("\n", 0, i) + 1
            col = i - (text.rfind("\n", 0, i) + 1) + 1
            raise MergeError(f"expected ':' in {path}: line {line} column {col}")
        i = _consume_json_value(text, i + 1, allow_comments, path)
        i = _skip_ws_comments(text, i, allow_comments)
        if i < len(text) and text[i] == ",":
            i = _skip_ws_comments(text, i + 1, allow_comments)
            if allow_comments and i < len(text) and text[i] == "}":
                return i + 1
            continue
        if i < len(text) and text[i] == "}":
            return i + 1
        line = text.count("\n", 0, i) + 1
        col = i - (text.rfind("\n", 0, i) + 1) + 1
        raise MergeError(f"invalid JSON object in {path}: line {line} column {col}")
    raise MergeError(f"unterminated JSON object in {path}")


def _find_object_key_span(text: str, obj_start: int, key: str, allow_comments: bool, path: Path) -> tuple[int, int, int, int]:
    """Return (key_start, colon_end, value_start, value_end) for key in object."""
    i = _skip_ws_comments(text, obj_start + 1, allow_comments)
    if i < len(text) and text[i] == "}":
        raise KeyError(key)
    while i < len(text):
        if text[i] != '"':
            line = text.count("\n", 0, i) + 1
            col = i - (text.rfind("\n", 0, i) + 1) + 1
            raise MergeError(f"expected object key in {path}: line {line} column {col}")
        key_start = i
        key_raw = json.loads(text[i:_skip_string(text, i)])
        i = _skip_string(text, i)
        i = _skip_ws_comments(text, i, allow_comments)
        if i >= len(text) or text[i] != ":":
            line = text.count("\n", 0, i) + 1
            col = i - (text.rfind("\n", 0, i) + 1) + 1
            raise MergeError(f"expected ':' in {path}: line {line} column {col}")
        colon_end = i + 1
        value_start = _skip_ws_comments(text, colon_end, allow_comments)
        value_end = _consume_json_value(text, value_start, allow_comments, path)
        if key_raw == key:
            return key_start, colon_end, value_start, value_end
        i = _skip_ws_comments(text, value_end, allow_comments)
        if i < len(text) and text[i] == ",":
            i = _skip_ws_comments(text, i + 1, allow_comments)
            if allow_comments and i < len(text) and text[i] == "}":
                break
            continue
        if i < len(text) and text[i] == "}":
            break
        line = text.count("\n", 0, i) + 1
        col = i - (text.rfind("\n", 0, i) + 1) + 1
        raise MergeError(f"invalid JSON object in {path}: line {line} column {col}")
    raise KeyError(key)


def _parse_json_like(text: str, path: Path, allow_comments: bool) -> Any:
    if allow_comments:
        stripped = _strip_json_comments(text, path)
        try:
            return json.loads(stripped)
        except json.JSONDecodeError as exc:
            raise MergeError(
                f"invalid JSON in {path}: line {exc.lineno} column {exc.colno}: {exc.msg}"
            ) from exc
    try:
        return json.loads(text)
    except json.JSONDecodeError as exc:
        raise MergeError(
            f"invalid JSON in {path}: line {exc.lineno} column {exc.colno}: {exc.msg}"
        ) from exc


def _strip_json_comments(text: str, path: Path) -> str:
    """Strip // and /* */ comments while preserving string literals and length."""
    out: list[str] = []
    i = 0
    in_string = False
    string_delim = '"'
    while i < len(text):
        ch = text[i]
        nxt = text[i + 1] if i + 1 < len(text) else ""
        if in_string:
            out.append(ch)
            if ch == "\\":
                if i + 1 < len(text):
                    out.append(text[i + 1])
                    i += 2
                    continue
            elif ch == string_delim:
                in_string = False
            i += 1
            continue
        if ch == '"':
            in_string = True
            out.append(ch)
            i += 1
            continue
        if ch == "/" and nxt == "/":
            j = text.find("\n", i + 2)
            if j < 0:
                out.append(" " * (len(text) - i))
                break
            out.append(" " * (j - i))
            out.append("\n")
            i = j + 1
            continue
        if ch == "/" and nxt == "*":
            j = text.find("*/", i + 2)
            if j < 0:
                raise MergeError(f"unterminated block comment in {path}")
            comment = text[i : j + 2]
            # Preserve newlines to keep line/col mapping stable-ish for value parsing.
            out.append("".join("\n" if c == "\n" else " " for c in comment))
            i = j + 2
            continue
        out.append(ch)
        i += 1
    return "".join(out)


def _detect_json_indent(text: str, obj_start: int, key_start: int) -> str:
    line_start = text.rfind("\n", 0, key_start) + 1
    indent = text[line_start:key_start]
    if indent.strip("") == "":
        return indent
    return "  "


def _render_json_value(value: Any, indent: str, key_col: int) -> str:
    raw = json.dumps(value, indent=2, ensure_ascii=False)
    if "\n" not in raw:
        return raw
    # Indent subsequent lines by key column.
    pad = " " * key_col
    lines = raw.splitlines()
    return "\n".join([lines[0], *[pad + line for line in lines[1:]]])


def _replace_dotted_json_key(
    text: str, dotted: str, value: Any, path: Path, allow_comments: bool
) -> str:
    keys = [k for k in dotted.split(".") if k]
    if not keys:
        raise MergeError(f"empty slot path for {path}")

    # Ensure file parses.
    parsed = _parse_json_like(text, path, allow_comments)
    if not isinstance(parsed, dict):
        raise MergeError(f"top-level JSON value must be object: {path}")

    obj_start = _skip_ws_comments(text, 0, allow_comments)
    if obj_start >= len(text) or text[obj_start] != "{":
        raise MergeError(f"top-level JSON value must be object: {path}")

    current_obj = obj_start
    for key in keys[:-1]:
        try:
            _, _, value_start, value_end = _find_object_key_span(
                text, current_obj, key, allow_comments, path
            )
        except KeyError as exc:
            raise MergeError(f"missing slot path '{dotted}' in {path}: '{key}' not found") from exc
        inner_start = _skip_ws_comments(text, value_start, allow_comments)
        if inner_start >= len(text) or text[inner_start] != "{":
            raise MergeError(
                f"slot path '{dotted}' does not traverse objects at '{key}' in {path}"
            )
        current_obj = inner_start

    leaf = keys[-1]
    try:
        key_start, colon_end, value_start, value_end = _find_object_key_span(
            text, current_obj, leaf, allow_comments, path
        )
    except KeyError as exc:
        raise MergeError(f"missing slot key '{leaf}' in {path}") from exc

    key_col = key_start - (text.rfind("\n", 0, key_start) + 1)
    rendered = _render_json_value(value, _detect_json_indent(text, current_obj, key_start), key_col)
    # Preserve single space after colon if present.
    between = text[colon_end:value_start]
    if not between:
        between = " "
    # If original had comments between colon and value, keep them? No: the owned
    # region is the value; comments between colon and value belong to value area
    # and would be ambiguous. Preserve whitespace exactly as-is.
    return text[:colon_end] + between[: len(between) - len(between.lstrip(" \t"))] + ("" if between.lstrip(" \t") == "" else "") + rendered + text[value_end:]


def _replace_dotted_json_key_preserving_between(
    text: str, dotted: str, value: Any, path: Path, allow_comments: bool
) -> str:
    keys = [k for k in dotted.split(".") if k]
    if not keys:
        raise MergeError(f"empty slot path for {path}")
    parsed = _parse_json_like(text, path, allow_comments)
    if not isinstance(parsed, dict):
        raise MergeError(f"top-level JSON value must be object: {path}")
    obj_start = _skip_ws_comments(text, 0, allow_comments)
    if obj_start >= len(text) or text[obj_start] != "{":
        raise MergeError(f"top-level JSON value must be object: {path}")
    current_obj = obj_start
    for key in keys[:-1]:
        try:
            _, _, value_start, _value_end = _find_object_key_span(
                text, current_obj, key, allow_comments, path
            )
        except KeyError as exc:
            raise MergeError(
                f"missing slot path '{dotted}' in {path}: '{key}' not found"
            ) from exc
        inner_start = _skip_ws_comments(text, value_start, allow_comments)
        if inner_start >= len(text) or text[inner_start] != "{":
            raise MergeError(
                f"slot path '{dotted}' does not traverse objects at '{key}' in {path}"
            )
        current_obj = inner_start
    leaf = keys[-1]
    try:
        key_start, colon_end, value_start, value_end = _find_object_key_span(
            text, current_obj, leaf, allow_comments, path
        )
    except KeyError as exc:
        raise MergeError(f"missing slot key '{leaf}' in {path}") from exc
    key_col = key_start - (text.rfind("\n", 0, key_start) + 1)
    rendered = _render_json_value(value, "  ", key_col)
    # Preserve exact bytes between colon and the old value start (typically a space).
    return text[:value_start] + rendered + text[value_end:]


def _extract_dotted_json_value(
    text: str, dotted: str, path: Path, allow_comments: bool
) -> Any:
    data = _parse_json_like(text, path, allow_comments)
    cur: Any = data
    for key in [k for k in dotted.split(".") if k]:
        if not isinstance(cur, dict) or key not in cur:
            raise MergeError(f"missing slot path '{dotted}' in {path}")
        cur = cur[key]
    return cur


# ---- YAML surgical replacement --------------------------------------------

def _yaml_item_range(text: str, list_key: str, item_key: str, item_name: str, path: Path) -> tuple[int, int]:
    """Find start/end span of a mapping item in a top-level-ish YAML sequence.

    The YAML merge contract is narrow: custom_providers is a list keyed by name.
    We scan textually for '- name: <item_name>' at either sequence indentation
    and replace that whole item block up to next item or end of list block.
    """
    # Locate list key line.
    key_re = re.compile(rf"^(?P<ind>[ \t]*){re.escape(list_key)}:\s*(?:#.*)?$", re.M)
    m = key_re.search(text)
    if not m:
        raise MergeError(f"missing YAML key '{list_key}' in {path}")
    list_indent = m.group("ind")
    item_indent = list_indent + "  "
    # Find items after list key.
    pos = m.end()
    # WHY: PyYAML emits indentless sequence dashes when a minimal target is
    # created, while _render_yaml_item and existing configs use two spaces.
    # Both spell the same slot, and create-then-remerge must converge.
    dash_indent = rf"(?:{re.escape(item_indent)}|{re.escape(list_indent)})"
    item_re = re.compile(rf"^(?P<ind>{dash_indent})-\s+{re.escape(item_key)}:\s*{re.escape(item_name)}\s*(?:#.*)?$", re.M)

    # Find target item.
    im = item_re.search(text, pos)
    if not im:
        raise MergeError(f"missing YAML item {item_key}={item_name} in {list_key} in {path}")
    start = im.start()
    # End is the next item at the target's own indentation, the next key at
    # list indentation, or EOF. Deriving this from the match keeps an
    # indentless created file stable across repeated merges.
    target_indent = im.group("ind")
    next_item_re = re.compile(rf"^(?P<ind>{re.escape(target_indent)})-\s+\S", re.M)
    next_top_re = re.compile(rf"^(?P<ind>{re.escape(list_indent)})\S", re.M)

    end = len(text)
    for nm in next_item_re.finditer(text, im.end()):
        if nm.start() > start:
            end = nm.start()
            break
    nt = next_top_re.search(text, im.end())
    if nt and nt.start() < end:
        end = nt.start()
    return start, end


def _render_yaml_item(item: dict[str, Any], item_indent: str) -> str:
    dumped = yaml.safe_dump(item, sort_keys=False, allow_unicode=False)
    # yaml.safe_dump emits a mapping; convert to list-item form.
    lines = dumped.rstrip("\n").splitlines()
    if not lines:
        return f"{item_indent}- {{}}\n"
    first = lines[0]
    out = [f"{item_indent}- {first}"]
    cont_indent = item_indent + "  "
    for line in lines[1:]:
        if line:
            out.append(f"{cont_indent}{line}")
        else:
            out.append("")
    return "\n".join(out) + "\n"


def _replace_yaml_named_item(text: str, slot: dict[str, Any], value: Any, path: Path) -> str:
    list_key = slot.get("listKey")
    item_key = slot.get("itemKey", "name")
    item_name = slot.get("itemName")
    if not isinstance(list_key, str) or not isinstance(item_name, str):
        raise MergeError(f"YAML slot requires listKey and itemName in {path}")
    if not isinstance(value, dict):
        raise MergeError(f"YAML named item payload must be mapping for {path}")

    # Validate parse first.
    try:
        data = yaml.safe_load(text)
    except yaml.YAMLError as exc:
        raise MergeError(f"invalid YAML in {path}: {exc}") from exc
    if not isinstance(data, dict):
        raise MergeError(f"top-level YAML must be mapping: {path}")

    start, end = _yaml_item_range(text, list_key, item_key, item_name, path)
    # Determine item indentation from actual item.
    m = re.match(r"[ \t]*", text[start:])
    item_indent = m.group(0) if m else "  "
    rendered = _render_yaml_item(value, item_indent)
    return text[:start] + rendered + text[end:]


def _extract_yaml_named_item(text: str, slot: dict[str, Any], path: Path) -> Any:
    list_key = slot.get("listKey")
    item_key = slot.get("itemKey", "name")
    item_name = slot.get("itemName")
    if not isinstance(list_key, str) or not isinstance(item_name, str):
        raise MergeError(f"YAML slot requires listKey and itemName in {path}")
    try:
        data = yaml.safe_load(text)
    except yaml.YAMLError as exc:
        raise MergeError(f"invalid YAML in {path}: {exc}") from exc
    if not isinstance(data, dict):
        raise MergeError(f"top-level YAML must be mapping: {path}")
    items = data.get(list_key)
    if not isinstance(items, list):
        raise MergeError(f"missing YAML key '{list_key}' in {path}")
    for item in items:
        if isinstance(item, dict) and item.get(item_key) == item_name:
            return item
    raise MergeError(f"missing YAML item {item_key}={item_name} in {list_key} in {path}")


# ---- TOML surgical replacement --------------------------------------------

_TOML_BARE_KEY = re.compile(r"[A-Za-z0-9_-]+")


def _toml_key_match(line: str, key: str) -> bool:
    # Match `key = ...` at line start, allowing quoted key or bare key.
    stripped = line.lstrip()
    if stripped.startswith("#"):
        return False
    for candidate in (key, f'"{key}"', f"'{key}'"):
        if stripped == candidate or stripped.startswith(candidate):
            rest = stripped[len(candidate):]
            if rest.startswith((" ", "\t", "=")):
                return True
    return False


def _replace_toml_top_level_key(text: str, key: str, value: Any, path: Path) -> str:
    if not isinstance(value, str):
        raise MergeError(f"TOML top-level key '{key}' payload must be string for {path}")
    lines = text.splitlines(keepends=True)
    out: list[str] = []
    replaced = False
    i = 0
    while i < len(lines):
        line = lines[i]
        if _toml_key_match(line, key):
            indent = line[: len(line) - len(line.lstrip(" \t"))]
            rendered = f"{indent}{key} = {json.dumps(value)}"
            # Preserve trailing newline style of original line.
            ending = "\n" if line.endswith("\n") else ""
            out.append(rendered + ending)
            replaced = True
            i += 1
            continue
        out.append(line)
        i += 1
    if not replaced:
        # Insert before first table header if present, else at top.
        insert_at = 0
        for idx, line in enumerate(out):
            if line.lstrip().startswith("["):
                insert_at = idx
                break
        else:
            insert_at = len(out)
        out.insert(insert_at, f"{key} = {json.dumps(value)}\n")
    return "".join(out)


def _find_toml_table_range(text: str, table: str, path: Path) -> tuple[int, int] | None:
    # Find `[table]` header line start/end span until next table header that is
    # not a child subtable (`[table.something]`). This is intentionally narrow
    # and refuses ambiguous multiline-string cases by not trying to parse them.
    header_re = re.compile(rf"(?m)^[ \t]*\[{re.escape(table)}\][ \t]*(?:#.*)?\r?\n?")
    m = header_re.search(text)
    if not m:
        return None
    start = m.start()
    i = m.end()
    next_header = re.compile(r"(?m)^[ \t]*\[([^\]]+)\][ \t]*(?:#.*)?\r?\n?")
    end = len(text)
    for n in next_header.finditer(text, i):
        name = n.group(1).strip()
        # A child table like [table.sub] belongs to this table's span; stop at
        # any non-child header.
        if name == table or name.startswith(table + "."):
            continue
        end = n.start()
        break
    return start, end


def _render_toml_table(table: str, value: Any, path: Path) -> str:
    if not isinstance(value, dict):
        raise MergeError(f"TOML table payload must be object for {path}")
    lines = [f"[{table}]"]
    for k, v in value.items():
        if not isinstance(k, str) or not _TOML_BARE_KEY.fullmatch(k):
            raise MergeError(f"unsupported TOML key in payload for {path}: {k!r}")
        lines.append(f"{k} = {_toml_scalar(v, path)}")
    return "\n".join(lines) + "\n"


def _toml_scalar(value: Any, path: Path) -> str:
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, int) and not isinstance(value, bool):
        return str(value)
    if isinstance(value, float):
        return repr(value)
    if isinstance(value, str):
        return json.dumps(value)
    if isinstance(value, list):
        return "[" + ", ".join(_toml_scalar(v, path) for v in value) + "]"
    if isinstance(value, dict):
        # Inline table.
        items = []
        for k, v in value.items():
            if not isinstance(k, str) or not _TOML_BARE_KEY.fullmatch(k):
                raise MergeError(f"unsupported TOML inline key for {path}: {k!r}")
            items.append(f"{k} = {_toml_scalar(v, path)}")
        return "{ " + ", ".join(items) + " }"
    if value is None:
        raise MergeError(f"TOML does not support null values in {path}")
    raise MergeError(f"unsupported TOML value type in {path}: {type(value).__name__}")


def _replace_toml_table(text: str, table: str, value: Any, path: Path) -> str:
    rendered = _render_toml_table(table, value, path)
    rng = _find_toml_table_range(text, table, path)
    if rng is None:
        # Append at end, preserving file's trailing newline behavior.
        prefix = text
        if prefix and not prefix.endswith("\n"):
            prefix += "\n"
        if prefix and not prefix.endswith("\n\n"):
            # separate from previous content by one blank line
            return prefix + "\n" + rendered
        return prefix + rendered
    start, end = rng
    return text[:start] + rendered + text[end:]


def _validate_toml_text(text: str, path: Path) -> None:
    if tomllib is None:
        # Without tomllib we cannot reliably validate; fail loudly rather than
        # risk corrupting a file we cannot parse.
        raise MergeError(
            f"tomllib unavailable; cannot safely parse TOML file {path}"
        )
    try:
        tomllib.loads(text)
    except Exception as exc:
        lineno = getattr(exc, "lineno", None)
        colno = getattr(exc, "colno", None)
        msg = getattr(exc, "msg", str(exc))
        if isinstance(lineno, int) and isinstance(colno, int):
            raise MergeError(
                f"invalid TOML in {path}: line {lineno} column {colno}: {msg}"
            ) from exc
        raise MergeError(f"invalid TOML in {path}: {msg}") from exc


def _extract_toml_slot(text: str, slot: dict[str, Any], path: Path) -> Any:
    # Validate whole file first: corrupt files must be hard errors.
    _validate_toml_text(text, path)
    top_key = slot.get("topLevelKey")
    table = slot.get("table")
    result: dict[str, Any] = {}
    if isinstance(top_key, str):
        m = re.search(rf"(?m)^[ \t]*{re.escape(top_key)}\s*=\s*(.+?)\s*$", text)
        if not m:
            raise MergeError(f"missing TOML key '{top_key}' in {path}")
        raw = m.group(1)
        try:
            result[top_key] = json.loads(raw)
        except Exception as exc:
            raise MergeError(f"invalid TOML scalar for '{top_key}' in {path}: {raw}") from exc
    if isinstance(table, str):
        rng = _find_toml_table_range(text, table, path)
        if rng is None:
            raise MergeError(f"missing TOML table '[{table}]' in {path}")
        block = text[rng[0]:rng[1]]
        # Parse simple key = scalar lines; our payload is flat.
        tbl: dict[str, Any] = {}
        for line in block.splitlines()[1:]:
            s = line.strip()
            if not s or s.startswith("#"):
                continue
            if "=" not in s:
                continue
            k, v = s.split("=", 1)
            k = k.strip()
            v = v.strip()
            try:
                tbl[k] = json.loads(v)
            except Exception:
                if v == "true":
                    tbl[k] = True
                elif v == "false":
                    tbl[k] = False
                else:
                    try:
                        tbl[k] = int(v)
                    except Exception as exc:
                        raise MergeError(f"unsupported TOML value in {path}: {line}") from exc
        result[table] = tbl
    return result


# ---- Slot dispatch ---------------------------------------------------------

def _slot_kind(slot: dict[str, Any]) -> str:
    kind = slot.get("kind")
    if isinstance(kind, str) and kind:
        return kind
    # Infer from fields for brevity.
    if "listKey" in slot:
        return "yaml-named-item"
    if "table" in slot or "topLevelKey" in slot:
        return "toml-provider-table"
    if "matchKey" in slot:
        return "named-array-item"
    if "path" in slot:
        return "dotted-key"
    raise MergeError("slot must declare kind or inferable fields")


def _ensure_parent(path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)


def _create_minimal_file(entry: HarnessEntry, target: Path, value: Any) -> str:
    slot = entry.slot
    kind = _slot_kind(slot)
    if kind == "dotted-key":
        dotted = slot["path"]
        if not isinstance(dotted, str) or not dotted:
            raise MergeError(f"dotted-key slot missing path for {entry.harness}")
        keys = [k for k in dotted.split(".") if k]
        root: Any = {}
        cur = root
        for k in keys[:-1]:
            nxt: dict[str, Any] = {}
            cur[k] = nxt
            cur = nxt
        cur[keys[-1]] = value
        if entry.fmt == "jsonc":
            # JSONC file created as JSON; no comments to preserve yet.
            return _json_text(root)
        return _json_text(root)
    if kind == "named-array-item":
        arr_path = slot.get("arrayPath")
        item = value
        if not isinstance(item, dict):
            raise MergeError(f"named-array-item payload must be object for {entry.harness}")
        if arr_path in (None, "", "$", "@root"):
            data: Any = [item]
        else:
            if not isinstance(arr_path, str):
                raise MergeError(f"named-array-item arrayPath must be string for {entry.harness}")
            keys = [k for k in arr_path.split(".") if k]
            data = {}
            cur = data
            for k in keys[:-1]:
                nxt = {}
                cur[k] = nxt
                cur = nxt
            cur[keys[-1]] = [item]
        return _json_text(data)
    if kind == "yaml-named-item":
        list_key = slot.get("listKey")
        item_name = slot.get("itemName")
        item_key = slot.get("itemKey", "name")
        if not isinstance(list_key, str) or not isinstance(item_name, str):
            raise MergeError(f"yaml-named-item slot incomplete for {entry.harness}")
        if not isinstance(value, dict):
            raise MergeError(f"yaml-named-item payload must be mapping for {entry.harness}")
        item = dict(value)
        item.setdefault(item_key, item_name)
        doc = {list_key: [item]}
        return yaml.safe_dump(doc, sort_keys=False, allow_unicode=False)
    if kind == "toml-provider-table":
        top_key = slot.get("topLevelKey")
        table = slot.get("table")
        parts: list[str] = []
        if isinstance(top_key, str):
            top_val = value.get(top_key) if isinstance(value, dict) else None
            if top_val is None:
                raise MergeError(
                    f"toml-provider-table payload missing '{top_key}' for {entry.harness}"
                )
            parts.append(f"{top_key} = {json.dumps(top_val)}")
        if isinstance(table, str):
            table_val = value.get(table) if isinstance(value, dict) else value
            if not isinstance(table_val, dict):
                raise MergeError(
                    f"toml-provider-table payload missing table '{table}' for {entry.harness}"
                )
            if parts:
                parts.append("")
            parts.append(_render_toml_table(table, table_val, target).rstrip("\n"))
        return "\n".join(parts).rstrip("\n") + "\n"
    raise MergeError(f"unsupported slot kind '{kind}' for {entry.harness}")


def _replace_named_array_item(text: str, slot: dict[str, Any], value: Any, path: Path) -> str:
    allow_comments = True  # jsonc tolerated; harmless for json
    parsed = _parse_json_like(text, path, allow_comments)
    match_key = slot.get("matchKey")
    match_value = slot.get("matchValue")
    arr_path = slot.get("arrayPath", "$")
    if not isinstance(match_key, str) or not isinstance(match_value, str):
        raise MergeError(f"named-array-item slot requires matchKey/matchValue for {path}")
    if not isinstance(value, dict):
        raise MergeError(f"named-array-item payload must be object for {path}")

    # Locate array start in text.
    obj_start = _skip_ws_comments(text, 0, allow_comments)
    if arr_path in ("$", "@root"):
        if obj_start >= len(text) or text[obj_start] != "[":
            raise MergeError(f"top-level JSON must be array for {path}")
        arr_start = obj_start
    else:
        if obj_start >= len(text) or text[obj_start] != "{":
            raise MergeError(f"top-level JSON must be object for {path}")
        keys = [k for k in str(arr_path).split(".") if k]
        cur = obj_start
        for i, key in enumerate(keys):
            try:
                _, _, vs, _ve = _find_object_key_span(text, cur, key, allow_comments, path)
            except KeyError as exc:
                raise MergeError(f"missing array path '{arr_path}' in {path}") from exc
            vs = _skip_ws_comments(text, vs, allow_comments)
            if i == len(keys) - 1:
                if text[vs] != "[":
                    raise MergeError(f"'{arr_path}' is not an array in {path}")
                arr_start = vs
            else:
                if text[vs] != "{":
                    raise MergeError(f"'{arr_path}' does not traverse objects in {path}")
                cur = vs
        else:
            arr_start = obj_start  # unreachable

    # Walk array items to find matching object.
    i = _skip_ws_comments(text, arr_start + 1, allow_comments)
    if i < len(text) and text[i] == "]":
        raise MergeError(f"named-array-item {match_key}={match_value} not found in {path}")
    while i < len(text):
        item_start = _skip_ws_comments(text, i, allow_comments)
        item_end = _consume_json_value(text, item_start, allow_comments, path)
        try:
            item_val = json.loads(_strip_json_comments(text[item_start:item_end], path))
        except Exception as exc:
            raise MergeError(f"invalid array item in {path}: {exc}") from exc
        if isinstance(item_val, dict) and item_val.get(match_key) == match_value:
            # Determine indentation for rendering.
            line_start = text.rfind("\n", 0, item_start) + 1
            item_col = item_start - line_start
            rendered = _render_json_value(value, "  ", item_col)
            return text[:item_start] + rendered + text[item_end:]
        i = _skip_ws_comments(text, item_end, allow_comments)
        if i < len(text) and text[i] == ",":
            i = _skip_ws_comments(text, i + 1, allow_comments)
            if i < len(text) and text[i] == "]":
                break
            continue
        if i < len(text) and text[i] == "]":
            break
        line = text.count("\n", 0, i) + 1
        col = i - (text.rfind("\n", 0, i) + 1) + 1
        raise MergeError(f"invalid JSON array in {path}: line {line} column {col}")
    raise MergeError(f"named-array-item {match_key}={match_value} not found in {path}")


def _extract_named_array_item(text: str, slot: dict[str, Any], path: Path) -> Any:
    allow_comments = True
    data = _parse_json_like(text, path, allow_comments)
    match_key = slot.get("matchKey")
    match_value = slot.get("matchValue")
    arr_path = slot.get("arrayPath", "$")
    if not isinstance(match_key, str) or not isinstance(match_value, str):
        raise MergeError(f"named-array-item slot requires matchKey/matchValue for {path}")
    arr: Any = data
    if arr_path not in ("$", "@root"):
        for k in [p for p in str(arr_path).split(".") if p]:
            if not isinstance(arr, dict) or k not in arr:
                raise MergeError(f"missing array path '{arr_path}' in {path}")
            arr = arr[k]
    if not isinstance(arr, list):
        raise MergeError(f"array path '{arr_path}' is not an array in {path}")
    for item in arr:
        if isinstance(item, dict) and item.get(match_key) == match_value:
            return item
    raise MergeError(f"named-array-item {match_key}={match_value} not found in {path}")


def _merge_text(entry: HarnessEntry, target: Path, text: str, value: Any) -> str:
    slot = entry.slot
    kind = _slot_kind(slot)
    allow_comments = entry.fmt == "jsonc"
    if kind == "dotted-key":
        dotted = slot.get("path")
        if not isinstance(dotted, str):
            raise MergeError(f"dotted-key slot missing path for {entry.harness}")
        return _replace_dotted_json_key_preserving_between(
            text, dotted, value, target, allow_comments
        )
    if kind == "named-array-item":
        return _replace_named_array_item(text, slot, value, target)
    if kind == "yaml-named-item":
        return _replace_yaml_named_item(text, slot, value, target)
    if kind == "toml-provider-table":
        if not isinstance(value, dict):
            raise MergeError(f"toml-provider-table payload must be object for {entry.harness}")
        _validate_toml_text(text, target)
        out = text
        top_key = slot.get("topLevelKey")
        table = slot.get("table")
        if isinstance(top_key, str):
            if top_key not in value:
                raise MergeError(
                    f"toml payload missing top-level key '{top_key}' for {entry.harness}"
                )
            out = _replace_toml_top_level_key(out, top_key, value[top_key], target)
        if isinstance(table, str):
            table_val = value.get(table)
            if table_val is None:
                raise MergeError(
                    f"toml payload missing table '{table}' for {entry.harness}"
                )
            out = _replace_toml_table(out, table, table_val, target)
        return out
    raise MergeError(f"unsupported slot kind '{kind}' for {entry.harness}")


def _extract_slot(entry: HarnessEntry, target: Path, text: str) -> Any:
    slot = entry.slot
    kind = _slot_kind(slot)
    allow_comments = entry.fmt == "jsonc"
    if kind == "dotted-key":
        dotted = slot.get("path")
        if not isinstance(dotted, str):
            raise MergeError(f"dotted-key slot missing path for {entry.harness}")
        return _extract_dotted_json_value(text, dotted, target, allow_comments)
    if kind == "named-array-item":
        return _extract_named_array_item(text, slot, target)
    if kind == "yaml-named-item":
        return _extract_yaml_named_item(text, slot, target)
    if kind == "toml-provider-table":
        return _extract_toml_slot(text, slot, target)
    raise MergeError(f"unsupported slot kind '{kind}' for {entry.harness}")


def _normalize_for_compare(entry: HarnessEntry, value: Any) -> Any:
    """Normalize values for semantic comparison in --check."""
    # For TOML slot extraction we return a dict with topLevelKey and/or table.
    # Payload should match that shape. Normalize through JSON round-trip for
    # stable dict/list types.
    return json.loads(json.dumps(value))


def _target_paths(entry: HarnessEntry, home: Path) -> list[tuple[str, Path]]:
    if isinstance(entry.path, str):
        return [(entry.harness, _resolve_home_path(entry.path, home))]
    # Host map.
    items = []
    for host in sorted(entry.path.keys()):
        items.append((f"{entry.harness}:{host}", _resolve_home_path(entry.path[host], home)))
    return items


def _payload_for_target(entry: HarnessEntry, repo_root: Path, target_label: str) -> Any:
    if isinstance(entry.path, dict):
        host = target_label.split(":", 1)[1]
        if isinstance(entry.payload, dict):
            host_payload = entry.payload.get(host)
            if not isinstance(host_payload, str):
                raise MergeError(f"{entry.harness}: missing payload for host {host}")
            # Load payload file specific to host.
            payload_entry = HarnessEntry(entry.harness, entry.path, entry.fmt, entry.slot, host_payload)
            payload = _payload_value(payload_entry, repo_root)
        else:
            payload = _payload_value(entry, repo_root)
            if isinstance(payload, dict) and set(payload.keys()) == set(entry.path.keys()):
                payload = payload[host]
        # For VS Code host-split files the expected value is the LiteLLM entry
        # inside the host chatLanguageModels file (plan B3).
        if entry.harness == "vscode" and _slot_kind(entry.slot) == "named-array-item":
            if isinstance(payload, list):
                mk = entry.slot.get("matchKey")
                mv = entry.slot.get("matchValue")
                for item in payload:
                    if isinstance(item, dict) and item.get(mk) == mv:
                        return item
                raise MergeError(f"{entry.harness}:{host}: payload missing {mk}={mv}")
            if isinstance(payload, dict) and payload.get(entry.slot.get("matchKey")) == entry.slot.get("matchValue"):
                return payload
        return payload
    payload = _payload_value(entry, repo_root)
    return payload


def _process_entry(
    entry: HarnessEntry, repo_root: Path, home: Path, check: bool
) -> tuple[list[str], list[str]]:
    changed: list[str] = []
    errors: list[str] = []
    for label, target in _target_paths(entry, home):
        try:
            payload = _payload_for_target(entry, repo_root, label)
        except Exception as exc:
            errors.append(f"{label}: {exc}")
            continue

        if not target.exists():
            if check:
                changed.append(f"{label}: missing target {target}")
                continue
            try:
                _ensure_parent(target)
                content = _create_minimal_file(entry, target, payload)
                target.write_text(content, encoding="utf-8")
                changed.append(f"{label}: created {target}")
            except Exception as exc:
                errors.append(f"{label}: cannot create {target}: {exc}")
            continue

        try:
            text = target.read_text(encoding="utf-8")
        except OSError as exc:
            errors.append(f"{label}: cannot read {target}: {exc}")
            continue

        try:
            if check:
                current = _extract_slot(entry, target, text)
                if _normalize_for_compare(entry, current) != _normalize_for_compare(entry, payload):
                    changed.append(f"{label}: slot drift in {target}")
                continue
            merged = _merge_text(entry, target, text, payload)
        except MergeError as exc:
            errors.append(f"{label}: {exc}")
            continue
        except Exception as exc:
            errors.append(f"{label}: unexpected merge error in {target}: {exc}")
            continue

        if merged != text:
            if check:
                changed.append(f"{label}: would change {target}")
            else:
                try:
                    target.write_text(merged, encoding="utf-8")
                    changed.append(f"{label}: updated {target}")
                except OSError as exc:
                    errors.append(f"{label}: cannot write {target}: {exc}")
    return changed, errors


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Merge LiteLLM model slots into harness config files."
    )
    parser.add_argument(
        "--check",
        action="store_true",
        help="Do not write; exit non-zero if any harness slot drifts from payload.",
    )
    parser.add_argument(
        "--registry",
        type=Path,
        default=None,
        help="Registry JSON path (default: src/modules/configs/harness-models.json).",
    )
    parser.add_argument(
        "--home",
        type=Path,
        default=None,
        help="Home directory for resolving target paths (default: $HOME).",
    )
    parser.add_argument(
        "--repo-root",
        type=Path,
        default=None,
        help="Repository root for resolving payload/registry paths.",
    )
    parser.add_argument(
        "--harness",
        action="append",
        default=[],
        help="Only process this harness id (repeatable).",
    )
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    repo_root = args.repo_root.resolve() if args.repo_root else _repo_root()
    registry_path = args.registry.resolve() if args.registry else _default_registry()
    home = args.home.resolve() if args.home else Path.home().resolve()

    try:
        entries = _load_registry(registry_path)
    except MergeError as exc:
        _eprint(str(exc))
        return 1

    selected = set(args.harness or [])
    if selected:
        known = {e.harness for e in entries}
        unknown = sorted(selected - known)
        if unknown:
            _eprint(f"unknown harness ids: {', '.join(unknown)}")
            return 1
        entries = [e for e in entries if e.harness in selected]

    all_changed: list[str] = []
    all_errors: list[str] = []
    for entry in entries:
        changed, errors = _process_entry(entry, repo_root, home, args.check)
        all_changed.extend(changed)
        all_errors.extend(errors)

    for line in all_changed:
        if args.check:
            print(line)
        else:
            print(line)

    if all_errors:
        for err in all_errors:
            _eprint(err)
        return 1

    if args.check and all_changed:
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
