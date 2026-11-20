#!/usr/bin/env bash
# Service supervision layout: restart/supervisor tokens in service scripts must
# be justified, and the firing-policy matrix must cover every registry service.

set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=./test-lib.sh
. "$SCRIPT_DIR/test-lib.sh"

REPO_ROOT="$(CDPATH='' cd -- "$SCRIPT_DIR/../.." && pwd -P)"
readonly REPO_ROOT

init_test_state
require_command jq "services.json and matrix checks read structured data"
require_command python3 "token and matrix checks parse policy/script content"

test_restart_tokens_require_why() {
  local out
  out="$(python3 - "$REPO_ROOT" <<'PY'
import os, re, sys
root=sys.argv[1]
dirs=['src/scripts/services','src/platforms/macOS/scripts','src/platforms/Windows/modules']
tokens=[r'launchctl kickstart', r'launchctl bootout', r'launchctl bootstrap', r'systemctl restart', r'Restart-Service']
pat=re.compile('|'.join(tokens))
miss=[]
for d in dirs:
    base=os.path.join(root,d)
    if not os.path.isdir(base): continue
    for r,_,files in os.walk(base):
        for f in files:
            if not f.endswith(('.sh','.ps1','.psm1','.bash','.zsh')): continue
            path=os.path.join(r,f)
            rel=os.path.relpath(path,root)
            try:
                with open(path,encoding='utf-8') as fh:
                    lines=fh.readlines()
            except Exception:
                continue
            for i,l in enumerate(lines):
                if not pat.search(l): continue
                # WHY on the same line or on a preceding line in the same block.
                has=False
                for j in range(max(0,i-20), i+1):
                    if '# WHY' in lines[j] or 'WHY:' in lines[j]:
                        has=True; break
                if not has:
                    miss.append(f'{rel}:{i+1}:{l.rstrip()}')
if miss:
    print('\n'.join(miss))
    sys.exit(1)
print('ok')
PY
  )" || {
    assert_fail "restart tokens carry a WHY" "$out"
    return
  }
  assert_pass "restart tokens in service scripts carry a WHY"
}

test_policy_matrix_covers_registry_services() {
  local out
  out="$(python3 - "$REPO_ROOT" <<'PY'
import json, re, sys, os
root=sys.argv[1]
with open(os.path.join(root,'src/modules/services.json'),encoding='utf-8') as f:
    data=json.load(f)
services=[k for k in data.keys() if not k.startswith('$')]
with open(os.path.join(root,'.agents/instructions/service-firing-policy.reference.md'),encoding='utf-8') as f:
    policy=f.read()
missing=[]
for s in services:
    # service id appears as backticked token in policy/matrix text
    if f'`{s}`' not in policy and f'| {s} |' not in policy and f'| `{s}` |' not in policy:
        missing.append(s)
if missing:
    print('missing from service-firing-policy.reference.md: ' + ', '.join(sorted(missing)))
    sys.exit(1)
# matrix script entries: every concrete script path in the supervision matrix must exist.
script_paths=set(re.findall(r'`(src/[^`*\s]+|scripts/[^`*\s]+)`', policy))
bad=[p for p in sorted(script_paths) if '*' not in p and not os.path.exists(os.path.join(root,p))]
if bad:
    print('matrix references missing paths: ' + ', '.join(bad))
    sys.exit(1)
print('ok')
PY
  )" || {
    assert_fail "policy matrix covers registry services and existing script paths" "$out"
    return
  }
  assert_pass "policy matrix covers registry services and existing script paths"
}

section 1 "service supervision layout"
echo ""

test_restart_tokens_require_why
test_policy_matrix_covers_registry_services

finish_tests
