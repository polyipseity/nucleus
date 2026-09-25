#!/usr/bin/env bash
# Tests for the cooldown configuration in src/modules/configs/litellm/config.yml.
#
# These pin the state left behind after cooldown_handler.py (the
# _is_cooldown_required monkey-patch) was deleted in favour of litellm's native
# per-deployment allowed_fails_policy:
#   1. litellm_settings no longer registers a cooldown callback;
#   2. the CommandCode deployment's allowed_fails_policy lives in the
#      deployment's own top-level model_info.
#
# (2) is asserted structurally, not by presence, because placement decides
# effect: litellm 1.100.1 reads the policy only from the deployment's own
# model_info (router_utils/cooldown_handlers.py::_get_deployment_cooldown_policy),
# so the identical key under litellm_params is silently inert.
#
# Run with: bash tests/scripts/litellm-config-tests.sh
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=./test-lib.sh
. "$SCRIPT_DIR/test-lib.sh"

REPO_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/../.." && pwd)"
readonly REPO_ROOT
CONFIG_YML="$REPO_ROOT/src/modules/configs/litellm/config.yml"
readonly CONFIG_YML

require_command python3 "litellm config tests parse config.yml with Python"
if ! python3 -c "import yaml" 2>/dev/null; then
  assert_fail "prerequisite: PyYAML" "PyYAML is required to parse config.yml"
  finish_tests
fi

# Count litellm_settings.callbacks entries. Prints 0 when the key is absent.
callbacks_count() {
  python3 -c "
import sys, yaml
cfg = yaml.safe_load(open(sys.argv[1]))
print(len((cfg.get('litellm_settings') or {}).get('callbacks') or []))
" "$CONFIG_YML"
}

# Read a path out of the CommandCode deployment entry, or report why not.
commandcode_field() { # <top-level key> <litellm_params key>
  python3 -c "
import sys, yaml
cfg = yaml.safe_load(open(sys.argv[1]))
matches = [
    m for m in cfg.get('model_list', [])
    if (m.get('litellm_params') or {}).get('model') == 'openai/deepseek/deepseek-v4-flash'
]
if len(matches) != 1:
    print('NO-MATCH')
    raise SystemExit(0)
entry = matches[0]
top_level = entry.get(sys.argv[2]) or {}
nested = (entry.get('litellm_params') or {}).get(sys.argv[3]) or {}
policy = top_level.get('allowed_fails_policy') or {}
print(policy.get('BadRequestErrorAllowedFails', 'MISSING'))
print('present' if nested.get('allowed_fails_policy') is not None else 'absent')
" "$CONFIG_YML" "$1" "$2"
}

section "litellm-config" "cooldown configuration"

callbacks="$(callbacks_count)"
if [ "$callbacks" = "0" ]; then
  assert_pass "litellm_settings registers no callbacks entry"
else
  assert_fail "litellm_settings registers no callbacks entry" "callbacks count=$callbacks"
fi

fields="$(commandcode_field model_info litellm_params)"
allowed_fails="$(printf '%s\n' "$fields" | sed -n '1p')"
sibling="$(printf '%s\n' "$fields" | sed -n '2p')"

if [ "$allowed_fails" = "0" ]; then
  assert_pass "CommandCode allowed_fails_policy.BadRequestErrorAllowedFails is 0 in the deployment model_info"
else
  assert_fail "CommandCode allowed_fails_policy.BadRequestErrorAllowedFails is 0 in the deployment model_info" "got [$allowed_fails] from [$(printf '%s' "$fields" | tr '\n' ' ')]"
fi

if [ "$sibling" = "absent" ]; then
  assert_pass "CommandCode carries no inert allowed_fails_policy under litellm_params"
else
  assert_fail "CommandCode carries no inert allowed_fails_policy under litellm_params" "got [$sibling]"
fi

if [ ! -e "$REPO_ROOT/src/modules/configs/litellm/cooldown_handler.py" ]; then
  assert_pass "cooldown_handler.py is gone"
else
  assert_fail "cooldown_handler.py is gone" "file still present"
fi

finish_tests
