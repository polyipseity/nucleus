import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

root = Path(sys.argv[1])
spec_path = Path(sys.argv[2])
spec = json.loads(spec_path.read_text())


def resolve_script(name, ext):
    for rel in (Path('scripts') / f'{name}.{ext}', Path('src/scripts/services') / f'{name}.{ext}'):
        p = root / rel
        if p.exists():
            return p
    return root / 'scripts' / f'{name}.{ext}'


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


def norm(s):
    return s.replace('-', '').lower()


def pwsh_declared_tokens(ps1, env):
    # WHY: reflection via Get-Command is the bindability contract; source text is not.
    if shutil.which('pwsh') is None:
        raise RuntimeError('pwsh is required for pwsh bindability reflection')
    ps1_q = str(ps1).replace("'", "''")
    cmd = (
        "$c=Get-Command -Name '" + ps1_q + "' -ErrorAction Stop; "
        "@($c.Parameters.GetEnumerator() | ForEach-Object { "
        "[pscustomobject]@{name=$_.Key; aliases=@($_.Value.Aliases)} }) | ConvertTo-Json -Compress -Depth 4"
    )
    r = subprocess.run(
        ['pwsh', '-NoLogo', '-NoProfile', '-NonInteractive', '-Command', cmd],
        capture_output=True, text=True, env=env,
    )
    if r.returncode != 0:
        raise RuntimeError(((r.stdout or '') + '\n' + (r.stderr or '')).strip())
    raw = (r.stdout or '').strip()
    if not raw or raw == 'null':
        items = []
    else:
        data = json.loads(raw)
        items = [data] if isinstance(data, dict) else (data if isinstance(data, list) else [])
    tokens = set()
    for item in items:
        if not isinstance(item, dict):
            continue
        n = item.get('name')
        if isinstance(n, str) and n:
            tokens.add(norm(n))
        aliases = item.get('aliases')
        if isinstance(aliases, list):
            for a in aliases:
                if isinstance(a, str) and a:
                    tokens.add(norm(a))
        elif isinstance(aliases, str) and aliases:
            tokens.add(norm(aliases))
    return tokens, len(items)


def pwsh_spec_to_reflection(name, ps1, sf, env):
    try:
        tokens, param_count = pwsh_declared_tokens(ps1, env)
    except Exception as e:
        return [f'{name}: pwsh reflection failed: {e}']
    if param_count == 0:
        # Hand-parsed script with no param() block: Get-Command exposes no parameter
        # metadata, so fall back to runtime help output (not source text).
        r = subprocess.run(
            ['pwsh', '-NoLogo', '-NoProfile', '-NonInteractive', '-File', str(ps1), '--help'],
            capture_output=True, text=True, env=env,
        )
        gh = subprocess.run(
            ['pwsh', '-NoLogo', '-NoProfile', '-NonInteractive', '-Command',
             f"Get-Help -Full '{str(ps1).replace(chr(39), chr(39) * 2)}' | Out-String -Width 4096"],
            capture_output=True, text=True, env=env,
        )
        corpus_norm = norm(
            (r.stdout or '') + '\n' + (r.stderr or '') + '\n' +
            (gh.stdout or '') + '\n' + (gh.stderr or '')
        )
        errs = []
        for flag in sorted(sf):
            if norm(flag) not in corpus_norm:
                errs.append(f'{name}: spec flag {flag} missing from pwsh help (no param metadata)')
        return errs
    errs = []
    for flag in sorted(sf):
        if norm(flag) not in tokens:
            errs.append(f'{name}: spec flag {flag} not bindable in pwsh (missing declared parameter/alias)')
    return errs


errors = []
env = dict(os.environ)
env['NUCLEUS_REPO_ROOT'] = str(root)
for app in spec.get('apps') or []:
    name = app.get('name')
    if not name:
        continue
    sf = spec_flags(app)
    hp = resolve_script(name, 'sh')
    ps1 = resolve_script(name, 'ps1')
    bash_err = None
    if hp.exists():
        r = subprocess.run(['bash', str(hp), '--help'], capture_output=True, text=True, env=env)
        if r.returncode == 0:
            text = (r.stdout or '') + '\n' + (r.stderr or '')
            hf = extract_long_flags(text)
            for flag in sorted(hf - sf):
                errors.append(f'{name}: help flag {flag} missing from spec')
            for flag in sorted(sf - hf):
                errors.append(f'{name}: spec flag {flag} missing from help')
            continue
        bash_err = ((r.stdout or '') + '\n' + (r.stderr or '')).strip()
    if ps1.exists():
        errors.extend(pwsh_spec_to_reflection(name, ps1, sf, env))
        continue
    if bash_err is not None:
        errors.append(f'{name}: --help failed (exit non-zero): {bash_err}')
        continue
    errors.append(f'{name}: help source not found: {hp}')

if errors:
    for e in errors:
        print(e)
    sys.exit(1)
