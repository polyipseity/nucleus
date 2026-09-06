"""
Cooldown monkey-patch for credit-exhaustion HTTP 400 errors.

LiteLLM's _is_cooldown_required excludes all 4xx except 429/401/408/404
from cooldown.  Providers that answer "insufficient credits" with HTTP 400
(e.g. CommandCode) are never cooled down.  This module patches the gate
to also return True for 400s whose exception message matches known
credit-exhaustion patterns.

Loaded as a litellm callback via `callbacks: ["litellm-cooldown-400.instance"]`
in litellm_settings.  The monkey-patch runs at module import time (before
any routing).  The _NoopCooldownPatch class satisfies litellm's callback
interface.

REMOVAL CONDITION:
  Remove this entire file, the `callbacks` entry in litellm-config.yml,
  and both symlinks (apply.sh, Sync-LiteLLMService.ps1) once litellm is
  updated to a release containing https://github.com/BerriAI/litellm/pull/34416
  (per-deployment allowed_fails_policy with _is_cooldown_required gate fix).
  The trigger: litellm >= version that merges #34416 to PyPI.
"""

from __future__ import annotations

import functools as _functools
import re as _re

from litellm.integrations.custom_logger import CustomLogger
from litellm.router_utils.cooldown_handlers import (
    _is_cooldown_required as _original_is_cooldown_required,
)

# --- Regex: credit-exhaustion patterns ---

_CREDIT_EXHAUSTION_RE = _re.compile(
    r"\b("
    r"insufficient.?credit"
    r"|credit.?exhaust"
    r"|usage.?limit"
    r"|quota.?exceed"
    r"|budget.?exceed"
    r"|payment.?require"
    r"|exceed(?:s|ed)?\s+(?:your|the)\s+(?:credit|quota|budget|usage)"
    r"|not\s+enough\s+(?:credit|balance|quota)"
    r")\b",
    _re.IGNORECASE,
)

# --- Monkey-patch ---
#
# Actual signature (litellm 1.89.0, cooldown_handlers.py:40):
#   _is_cooldown_required(
#       litellm_router_instance: LitellmRouter,
#       model_id: str,
#       exception_status: Union[str, int],
#       exception_str: Optional[str] = None,
#   ) -> bool
#
# Called from _should_run_cooldown_logic (line 148):
#   _is_cooldown_required(
#       litellm_router_instance=litellm_router_instance,
#       model_id=deployment,
#       exception_status=exception_status,
#       exception_str=str(original_exception),
#   )


@_functools.wraps(_original_is_cooldown_required)
def _patched_is_cooldown_required(
    litellm_router_instance: object,
    model_id: str,
    exception_status: object,
    exception_str: str | None = None,
) -> bool:
    try:
        status_int = int(exception_status) if exception_status else 0
    except (ValueError, TypeError):
        status_int = 0

    if (
        status_int == 400
        and exception_str is not None
        and _CREDIT_EXHAUSTION_RE.search(exception_str)
    ):
        return True

    return _original_is_cooldown_required(
        litellm_router_instance=litellm_router_instance,
        model_id=model_id,
        exception_status=exception_status,
        exception_str=exception_str,
    )


import litellm.router_utils.cooldown_handlers as _cooldown_mod

_cooldown_mod._is_cooldown_required = _patched_is_cooldown_required  # type: ignore[misc]

# --- Callback stub (required by litellm's callback system) ---


class _NoopCooldownPatch(CustomLogger):
    """Placeholder callback.  The real work is the module-level monkey-patch."""


instance = _NoopCooldownPatch()
