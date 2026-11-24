# Step 10: autocompletion freshness (PowerShell).
#
# Verifies that the generated completer flag inventory in profile.ps1 matches
# src/scripts/completions/gen-completions.ps1 (drift), that every nucleus-* command has both a
# zsh _nucleus-<cmd> file and a pwsh completer entry with a defined flag
# inventory (coverage), that every flag inventory the profile references is
# defined in it (referenced-vs-defined), and that the -Sections value completion
# in the bump-lockfile completer still has its --list-sections contract
# (introspection).

Register-Step -Id "completions-fresh" -Name "Autocompletion freshness" -Platform windows -Mode full -Requires none -Action {
  param([Parameter(Mandatory)][PSObject]$Context)

  $RepoRoot = $Context.RepoRoot

  $r = if ($RepoRoot) { $RepoRoot } else { Split-Path -Parent (Split-Path -Parent $PSScriptRoot) }

  $fmtDur = {
    param([datetime]$Start)
    '{0:N3} s' -f (([datetime]::UtcNow - $Start).TotalSeconds)
  }

  Write-Message "--- generated completer inventory matches generator ---"
  $t0 = [datetime]::UtcNow
  & (Join-Path $r 'src\scripts\completions\gen-completions.ps1') -Check
  if ($LASTEXITCODE -ne 0) {
    Write-ErrorMessage "src/scripts/shell/profile.ps1 is stale -- run src/scripts/completions/gen-completions.ps1"
    return $false
  }
  Write-Message "completions-fresh: gen-completions.ps1 --check: $(& $fmtDur $t0)"

  Write-Message "--- coverage: zsh + pwsh completions for every nucleus-* command ---"
  $t0 = [datetime]::UtcNow
  $commands = @(pwsh -NoLogo -NoProfile -NonInteractive -File (Join-Path $r 'src\scripts\completions\gen-completions.ps1') -ListCommands | ForEach-Object { ($_ | Out-String).Trim() } | Where-Object { $_ -ne '' })
  if ($commands.Count -eq 0) {
    Write-ErrorMessage "could not derive nucleus command list from gen-completions.ps1 -ListCommands"
    return $false
  }
  $profilePath = Join-Path $r 'src/scripts/shell/profile.ps1'
  $zshDir = Join-Path $r 'src/modules/completions/zsh'
  $profileText = [System.IO.File]::ReadAllText($profilePath)
  $missing = @()
  foreach ($command in $commands) {
    $pascal = (($command.Split('-') | ForEach-Object { $_.Substring(0, 1).ToUpperInvariant() + $_.Substring(1) }) -join '')
    $hasZsh = Test-Path -Path (Join-Path $zshDir "_nucleus-$command") -PathType Leaf
    # WHY: match the registration at the line start, so a mention inside a comment
    # or another command's name cannot stand in for a real entry.
    $hasCompleter = [regex]::IsMatch($profileText, "(?m)^Register-ArgumentCompleter -CommandName nucleus-$command\s")
    # WHY: anchored to the line start with '=', the definition. The completer body
    # mentions the same variable, so a name-anywhere match stayed green while
    # nothing defined it, which is how the missing utils inventory shipped.
    $hasFlagVar = [regex]::IsMatch($profileText, "(?m)^\`$nucleus${pascal}Flags\s*=")
    if (-not ($hasZsh -and $hasCompleter -and $hasFlagVar)) {
      $missing += "$command (zsh:$hasZsh completer:$hasCompleter flagvar:$hasFlagVar)"
    }
  }
  if ($missing.Count -gt 0) {
    Write-ErrorMessage "completions missing for: $($missing -join ', ')"
    return $false
  }

  # A completer naming a variable the generator no longer emits completes nothing.
  Write-Message "--- every referenced flag inventory is defined ---"
  $undefined = @()
  foreach ($name in @([regex]::Matches($profileText, '\$nucleus[A-Za-z0-9]*Flags\b') | ForEach-Object { $_.Value } | Sort-Object -Unique)) {
    if (-not [regex]::IsMatch($profileText, "(?m)^\$name\s*=")) {
      $undefined += $name
    }
  }
  if ($undefined.Count -gt 0) {
    Write-ErrorMessage "profile.ps1 references flag inventories that nothing defines: $($undefined -join ', ')"
    return $false
  }
  Write-Message "completions-fresh: coverage/defined checks: $(& $fmtDur $t0)"

  # --list-* flags wired via _call_program must exist in --help (E5).
  Write-Message "--- --list-* help/introspection contract ---"
  $t0 = [datetime]::UtcNow
  # WHY: probe the pwsh twin, the live Windows CLI. POSIX scripts like svc.sh reject
  # non-MacBook/NixOS hosts, so running them on Windows cannot validate Windows help.
  # WHY: normalization removes '-' and lowercases so Get-Help Pascal parameters
  # (-ListServices) and hand-written kebab usage (--list-services) both satisfy the
  # same --list-* flag wired in zsh completions.
  $oldRepoRoot = $env:NUCLEUS_REPO_ROOT
  try {
    $env:NUCLEUS_REPO_ROOT = $r
    foreach ($command in $commands) {
      $zshFile = Join-Path $zshDir "_nucleus-$command"
      if (-not (Test-Path -LiteralPath $zshFile -PathType Leaf)) { continue }
      $zshText = [System.IO.File]::ReadAllText($zshFile)
      if ($zshText -notmatch '_call_program') { continue }
      $ps1Path = Join-Path $r "scripts/$command.ps1"
      if (-not (Test-Path -LiteralPath $ps1Path -PathType Leaf)) { continue }
      $listFlags = @([regex]::Matches($zshText, '--list-[a-z0-9-]+') | ForEach-Object { $_.Value } | Sort-Object -Unique)
      if ($listFlags.Count -eq 0) { continue }
      $helpOut = & pwsh -NoLogo -NoProfile -NonInteractive -File $ps1Path --help 2>&1
      $helpExit = $LASTEXITCODE
      $helpText = (($helpOut | ForEach-Object { "$_" }) -join "`n")
      if ($helpExit -ne 0) {
        Write-ErrorMessage "nucleus-${command}: --help failed during introspection (exit $helpExit); output: $helpText"
        return $false
      }
      $ghOut = Get-Help -Full $ps1Path 2>&1 | ForEach-Object { "$_" }
      $ghText = ($ghOut -join "`n")
      $paramText = ''
      try { $paramText = ((Get-Command $ps1Path -ErrorAction Stop).Parameters.Keys -join ' ') } catch { $paramText = '' } # check-suppress:suppression_doc: parameter metadata is a best-effort help corpus supplement
      $corpusNorm = (($helpText + "`n" + $ghText + "`n" + $paramText) -replace '-', '').ToLowerInvariant()
      foreach ($flag in $listFlags) {
        $flagNorm = ($flag -replace '-', '').ToLowerInvariant()
        if (-not $corpusNorm.Contains($flagNorm)) {
          # WHY: some pwsh twins accept list flags through manual argument parsing and
          # do not enumerate them in --help/Get-Help; probing the live CLI confirms the
          # wired flag is actually handled.
          $probeOut = & pwsh -NoLogo -NoProfile -NonInteractive -File $ps1Path $flag 2>&1
          $probeExit = $LASTEXITCODE
          if ($probeExit -ne 0) {
            $probeText = (($probeOut | ForEach-Object { "$_" }) -join "`n")
            Write-ErrorMessage "nucleus-${command}: completion wires $flag but pwsh help/output lacks it (probe exit $probeExit): $probeText"
            return $false
          }
        }
      }
    }
  } finally {
    $env:NUCLEUS_REPO_ROOT = $oldRepoRoot
  }
  Write-Message "completions-fresh: help/--list-* introspection: $(& $fmtDur $t0)"

  # Provider commands must exit 0 (E5). Test against repo pwsh twins (not installed
  # binaries and not POSIX scripts, which may be host-gated on Windows).
  # Context-dependent providers ($words) are skipped unless resolved concretely.
  Write-Message "--- provider commands exit 0 ---"
  $t0 = [datetime]::UtcNow
  # WHY: probe pwsh twins, the live Windows CLI. POSIX scripts like svc.sh reject
  # non-MacBook/NixOS hosts and cannot validate Windows provider behavior.
  $oldRepoRoot = $env:NUCLEUS_REPO_ROOT
  try {
    $env:NUCLEUS_REPO_ROOT = $r
    foreach ($command in $commands) {
      $zshFile = Join-Path $zshDir "_nucleus-$command"
      if (-not (Test-Path -LiteralPath $zshFile -PathType Leaf)) { continue }
      $zshText = [System.IO.File]::ReadAllText($zshFile)
      $provCmds = @([regex]::Matches($zshText, "_call_program\s+'[^']+'\s+(?<cmd>[^\r\n]+)") | ForEach-Object { $_.Groups['cmd'].Value } | Sort-Object -Unique)
      foreach ($prov in $provCmds) {
        $testCmd = $prov
        # WHY: scripts/svc.ps1 handles `endpoint --list-endpoints` at line 933 after
        # the elevation gate at line 113, so probing it would self-elevate on CI.
        if ($testCmd -match 'endpoint\s+--list-endpoints') { continue }
        if ($testCmd -match '\$words') { continue }
        $mappedCmd = $null
        if ($testCmd -match '^nucleus-([a-z0-9-]+)(\s|$)') {
          $name = $Matches[1]
          $ps1Path = Join-Path $r "scripts/$name.ps1"
          if (-not (Test-Path -LiteralPath $ps1Path -PathType Leaf)) { continue }
          $quotedScriptPath = $ps1Path -replace "'", "''"
          $mappedCmd = "& '$quotedScriptPath'" + $testCmd.Substring(("nucleus-$name").Length)
        } else {
          continue
        }
        # Run via pwsh -Command so mapped provider pipelines (e.g. `... | jq`) and
        # argument structure from the completion command are preserved.
        $provOut = & pwsh -NoLogo -NoProfile -NonInteractive -Command $mappedCmd 2>&1
        $provExit = $LASTEXITCODE
        if ($provExit -ne 0) {
          $provText = (($provOut | ForEach-Object { "$_" }) -join "`n")
          $rawText = ''
          # WHY: the pipeline's stdout was consumed by the downstream filter; on
          # failure, re-run the producer alone so the error names its actual output.
          if ($mappedCmd -match '\s*\|\s*jq\b') {
            $rawCmd = $mappedCmd -replace '\s*\|\s*jq\b.*$', ''
            $rawOut = & pwsh -NoLogo -NoProfile -NonInteractive -Command $rawCmd 2>&1
            $rawExit = $LASTEXITCODE
            $rawText = "; raw: exit $rawExit output: $((($rawOut | ForEach-Object { "$_" }) -join "`n"))"
          }
          Write-ErrorMessage "nucleus-${command}: completion provider command exited non-zero (exit $provExit): $testCmd; output: $provText${rawText}"
          return $false
        }
      }
    }
  } finally {
    $env:NUCLEUS_REPO_ROOT = $oldRepoRoot
  }
  Write-Message "completions-fresh: provider commands: $(& $fmtDur $t0)"

  # Help/spec drift: spec long flags must appear in native Windows help when a pwsh
  # twin exists; commands without a twin fall back to POSIX .sh bidirectional drift.
  Write-Message "--- help/spec drift ---"
  $t0 = [datetime]::UtcNow
  $specPath = Join-Path $r 'src\modules\completions\nucleus-cli-spec.json'
  if (-not (Test-Path -Path $specPath -PathType Leaf)) {
    Write-ErrorMessage "nucleus CLI spec not found: $specPath"
    return $false
  }
  $py = Get-Command python3 -ErrorAction SilentlyContinue # check-suppress:suppression_doc: optional interpreter probe; absence handled below
  if (-not $py) { $py = Get-Command python -ErrorAction SilentlyContinue } # check-suppress:suppression_doc: optional interpreter probe; absence handled below
  if (-not $py) {
    Write-ErrorMessage "python is required for help/spec drift checking"
    return $false
  }
  # WHY: preserve the proven .sh bidirectional help/spec check where the POSIX
  # help source runs, and fall back to the pwsh twin only when the .sh probe fails
  # on this host (for example svc.sh rejects non-MacBook/NixOS hosts on Windows).
  # The pwsh fallback uses Get-Command reflection for bindability (declared
  # parameter names/aliases), not source-text or help-text corpus matching.
  $driftScript = @'
import json, os, re, shutil, subprocess, sys
from pathlib import Path
root = Path(sys.argv[1]); spec = json.loads(Path(sys.argv[2]).read_text())
def resolve_script(name, ext):
    for rel in (Path('scripts') / f'{name}.{ext}', Path('src/scripts/services') / f'{name}.{ext}'):
        p = root / rel
        if p.exists(): return p
    return root / 'scripts' / f'{name}.{ext}'
def extract_long_flags(text):
    out=set()
    for line in text.splitlines():
        if re.match(r'^(usage|Usage):', line):
            for grp in re.findall(r'\[([^\]]*(?:\[[^\]]*\][^\]]*)*)\]', line):
                for tok in re.findall(r'--[a-z0-9][a-z0-9-]*', grp):
                    out.add(tok)
        m = re.match(r'^[ \t]*((?:-|--)[a-z0-9][a-z0-9-]*(?:\s*[|,]\s*(?:-|--)[a-z0-9][a-z0-9-]*)*)', line)
        if m:
            for tok in re.findall(r'--[a-z0-9][a-z0-9-]*', m.group(1)):
                out.add(tok)
    return out
def spec_flag_applies(flag, platform):
    platforms = flag.get('platforms')
    if platforms is None:
        return True
    if not isinstance(platforms, list) or len(platforms) == 0:
        return True
    return platform in platforms
def spec_flags(app, platform):
    out=set()
    for f in app.get('globalFlags') or []:
        if f.get('long') and spec_flag_applies(f, platform):
            out.add(f['long'])
    for sc in app.get('subcommands') or []:
        for f in sc.get('flags') or []:
            if f.get('long') and spec_flag_applies(f, platform):
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
    r = subprocess.run(['pwsh', '-NoLogo', '-NoProfile', '-NonInteractive', '-Command', cmd], capture_output=True, text=True, env=env)
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
        return [f'{name}: pwsh reflection returned no declared parameters; spec flags cannot be verified']
    errs = []
    for flag in sorted(sf):
        if norm(flag) not in tokens:
            errs.append(f'{name}: spec flag {flag} not bindable in pwsh (missing declared parameter/alias)')
    return errs
errors=[]
env = dict(os.environ)
env['NUCLEUS_REPO_ROOT'] = str(root)
for app in spec.get('apps') or []:
    name=app.get('name')
    if not name: continue
    sf_posix=spec_flags(app, 'posix')
    sf_windows=spec_flags(app, 'windows')
    hp=resolve_script(name, 'sh')
    ps1=resolve_script(name, 'ps1')
    bash_err=None
    if hp.exists():
        r=subprocess.run(['bash', str(hp), '--help'], capture_output=True, text=True, env=env)
        if r.returncode == 0:
            text=(r.stdout or '')+'\n'+(r.stderr or '')
            hf=extract_long_flags(text)
            for flag in sorted(hf-sf_posix): errors.append(f'{name}: help flag {flag} missing from spec')
            for flag in sorted(sf_posix-hf): errors.append(f'{name}: spec flag {flag} missing from help')
            if ps1.exists():
                errors.extend(pwsh_spec_to_reflection(name, ps1, sf_windows, env))
            continue
        bash_err=((r.stdout or '')+'\n'+(r.stderr or '')).strip()
    if ps1.exists():
        errors.extend(pwsh_spec_to_reflection(name, ps1, sf_windows, env))
        continue
    if bash_err is not None:
        errors.append(f'{name}: --help failed (exit non-zero): {bash_err}')
        continue
    errors.append(f'{name}: help source not found: {hp}')
if errors:
    for e in errors: print(e)
    sys.exit(1)
'@
  $driftOut = & $py.Source -c $driftScript $r $specPath 2>&1
  if ($LASTEXITCODE -ne 0) {
    foreach ($line in @($driftOut)) {
      $text = ($line | Out-String).TrimEnd()
      if ($text) { Write-ErrorMessage $text }
    }
    Write-ErrorMessage "help/spec drift detected"
    return $false
  }
  Write-Message "completions-fresh: help/spec drift: $(& $fmtDur $t0)"

  Write-Message "completions are fresh."
  return $true
}
