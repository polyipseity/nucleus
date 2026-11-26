#!/usr/bin/env python3
"""Emit the LiteLLM alias limit table consumed by harness model provisioning.

Reads src/modules/configs/litellm/config.yml and writes one JSON object to
stdout mapping each distinct model_list[].model_name to its token limits:

    {
      "default":      {"maxInputTokens": 256000, "maxOutputTokens": 16000},
      "default-free": {"maxInputTokens": 256000, "maxOutputTokens": 16000}
    }

Rules:
- Commented deployments are ignored.
- A limit is the maximum across deployments that declare it; null when no
  deployment declares that limit.
- Conflicting non-null limits that cannot be reconciled are a hard error naming
  both deployments.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any

try:
    import yaml
except Exception as exc:  # pragma: no cover - exercised by runtime env
    print(f"litellm-aliases: cannot import yaml: {exc}", file=sys.stderr)
    raise SystemExit(2) from exc


LIMIT_FIELDS = ("max_input_tokens", "max_output_tokens")
OUTPUT_FIELDS = {
    "max_input_tokens": "maxInputTokens",
    "max_output_tokens": "maxOutputTokens",
}


class AliasError(ValueError):
    """Raised when the alias table cannot be derived safely."""


def _repo_root() -> Path:
    return Path(__file__).resolve().parents[3]


def _default_config() -> Path:
    return _repo_root() / "src/modules/configs/litellm/config.yml"


def _load_yaml(path: Path) -> dict[str, Any]:
    try:
        raw = path.read_text(encoding="utf-8")
    except FileNotFoundError as exc:
        raise AliasError(f"config not found: {path}") from exc
    except OSError as exc:
        raise AliasError(f"cannot read config {path}: {exc}") from exc

    try:
        data = yaml.safe_load(raw)
    except yaml.YAMLError as exc:
        raise AliasError(f"invalid YAML in {path}: {exc}") from exc

    if data is None:
        return {}
    if not isinstance(data, dict):
        raise AliasError(f"top-level YAML document must be a mapping: {path}")
    return data


def _deployment_label(deployment: dict[str, Any], index: int) -> str:
    litellm_params = deployment.get("litellm_params")
    model = None
    if isinstance(litellm_params, dict):
        raw_model = litellm_params.get("model")
        if isinstance(raw_model, str) and raw_model.strip():
            model = raw_model.strip()
    model_name = deployment.get("model_name")
    alias = model_name.strip() if isinstance(model_name, str) and model_name.strip() else f"<deployment {index}>"
    if model:
        return f"{alias} ({model})"
    return alias


def _extract_limit(deployment: dict[str, Any], field: str) -> int | None:
    candidates: list[int] = []
    for container_key in ("model_info",):
        container = deployment.get(container_key)
        if isinstance(container, dict) and field in container:
            candidates.append(_coerce_limit(container[field], field, deployment))
    litellm_params = deployment.get("litellm_params")
    if isinstance(litellm_params, dict):
        model_info = litellm_params.get("model_info")
        if isinstance(model_info, dict) and field in model_info:
            candidates.append(_coerce_limit(model_info[field], field, deployment))

    if not candidates:
        return None
    # Same deployment may declare the same field in more than one place; they
    # must agree or be absent. Divergence inside one deployment is ambiguous.
    first = candidates[0]
    for value in candidates[1:]:
        if value != first:
            label = _deployment_label(deployment, -1)
            raise AliasError(
                f"deployment {label} declares conflicting {field} values "
                f"{first} and {value}"
            )
    return first


def _coerce_limit(value: Any, field: str, deployment: dict[str, Any]) -> int:
    if isinstance(value, bool) or not isinstance(value, int):
        label = _deployment_label(deployment, -1)
        raise AliasError(
            f"deployment {label} declares non-integer {field}: {value!r}"
        )
    if value < 0:
        label = _deployment_label(deployment, -1)
        raise AliasError(
            f"deployment {label} declares negative {field}: {value!r}"
        )
    return value


def build_alias_table(data: dict[str, Any]) -> dict[str, dict[str, int | None]]:
    model_list = data.get("model_list")
    if model_list is None:
        return {}
    if not isinstance(model_list, list):
        raise AliasError("model_list must be a list")

    # alias -> field -> list[(value, label)]
    declared: dict[str, dict[str, list[tuple[int, str]]]] = {}
    order: list[str] = []

    for index, deployment in enumerate(model_list):
        if not isinstance(deployment, dict):
            raise AliasError(f"model_list[{index}] must be a mapping")
        raw_name = deployment.get("model_name")
        if not isinstance(raw_name, str) or not raw_name.strip():
            raise AliasError(f"model_list[{index}] is missing model_name")
        alias = raw_name.strip()
        if alias not in declared:
            declared[alias] = {field: [] for field in LIMIT_FIELDS}
            order.append(alias)

        label = _deployment_label(deployment, index)
        for field in LIMIT_FIELDS:
            value = _extract_limit(deployment, field)
            if value is not None:
                declared[alias][field].append((value, label))

    table: dict[str, dict[str, int | None]] = {}
    for alias in order:
        entry: dict[str, int | None] = {}
        for field in LIMIT_FIELDS:
            values = declared[alias][field]
            if not values:
                entry[OUTPUT_FIELDS[field]] = None
                continue

            distinct = {value for value, _label in values}
            # Plan rule: token limits are the maximum across the alias's
            # deployments. Differing declared non-null numeric limits are
            # reconciled by taking the maximum. Truly irreconcilable conflicts
            # (e.g. conflicting declarations inside one deployment) are errors.
            entry[OUTPUT_FIELDS[field]] = max(distinct)
        table[alias] = entry
    return table


def render_json(table: dict[str, dict[str, int | None]]) -> str:
    return json.dumps(table, indent=2, sort_keys=False) + "\n"


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Emit LiteLLM alias token limits as JSON."
    )
    parser.add_argument(
        "--config",
        type=Path,
        default=None,
        help="Path to litellm config.yml (default: repo src/modules/configs/litellm/config.yml)",
    )
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    config_path = args.config if args.config is not None else _default_config()
    try:
        table = build_alias_table(_load_yaml(config_path))
    except AliasError as exc:
        print(f"litellm-aliases: {exc}", file=sys.stderr)
        return 1
    sys.stdout.write(render_json(table))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
