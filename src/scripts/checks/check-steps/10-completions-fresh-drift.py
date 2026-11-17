import json
import re
import subprocess
import sys
from pathlib import Path

root = Path(sys.argv[1])
spec_path = Path(sys.argv[2])
spec = json.loads(spec_path.read_text())


def help_path(name):
    p = root / 'scripts' / f'{name}.sh'
    if p.exists():
        return p
    if name == 'camilladsp-heartbeat':
        return root / 'src/scripts/services/camilladsp-heartbeat.sh'
    return root / 'scripts' / f'{name}.sh'


def extract_long_flags(text):
    out = set()
    for line in text.splitlines():
        if re.match(r'^(usage|Usage):', line):
            # usage bracket groups, including nested [=<...>]
            for grp in re.findall(r'\[([^\]]*(?:\[[^\]]*\][^\]]*)*)\]', line):
                for tok in re.findall(r'--[a-z0-9][a-z0-9-]*', grp):
                    out.add(tok)
        m = re.match(r'^[ \t]*((?:-|--)[a-z0-9][a-z0-9-]*(?:\s*[|,]\s*(?:-|--)[a-z0-9][a-z0-9-]*)*)', line)
        if m:
            for tok in re.findall(r'--[a-z0-9][a-z0-9-]*', m.group(1)):
                out.add(tok)
    return out


def spec_flags(app):
    out = set()
    for f in app.get('globalFlags') or []:
        if f.get('long'):
            out.add(f['long'])
    for sc in app.get('subcommands') or []:
        for f in sc.get('flags') or []:
            if f.get('long'):
                out.add(f['long'])
    return out


errors = []
for app in spec.get('apps') or []:
    name = app.get('name')
    if not name:
        continue
    hp = help_path(name)
    if not hp.exists():
        errors.append(f'{name}: help source not found: {hp}')
        continue
    r = subprocess.run(['bash', str(hp), '--help'], capture_output=True, text=True)
    text = (r.stdout or '') + '\n' + (r.stderr or '')
    hf = extract_long_flags(text)
    sf = spec_flags(app)
    for flag in sorted(hf - sf):
        errors.append(f'{name}: help flag {flag} missing from spec')
    for flag in sorted(sf - hf):
        errors.append(f'{name}: spec flag {flag} missing from help')

if errors:
    for e in errors:
        print(e)
    sys.exit(1)
