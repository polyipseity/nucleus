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

  # The update lockfile completer completes -Sections, so update.sh needs -ListSections.
  Write-Message "--- --list-* introspection contract ---"
  $t0 = [datetime]::UtcNow
  $updatePath = Join-Path $r 'scripts\update.sh'
  if (-not (Select-String -Path $updatePath -Pattern 'list-sections' -SimpleMatch -Quiet)) {
    Write-ErrorMessage "scripts/update.sh lacks --list-sections, which the update lockfile completer depends on"
    return $false
  }
  Write-Message "completions-fresh: help/--list-* introspection: $(& $fmtDur $t0)"

  # Bidirectional help<->spec drift: every --long-flag token in an app's --help
  # must exist in the spec, and every spec long flag must appear in that help.
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
  $driftScript = @'
import json, re, subprocess, sys
from pathlib import Path
root = Path(sys.argv[1]); spec = json.loads(Path(sys.argv[2]).read_text())
def help_path(name):
    if name == 'camilladsp-heartbeat':
        return root / 'src/scripts/services/camilladsp-heartbeat.sh'
    return root / 'scripts' / f'{name}.sh'
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
def spec_flags(app):
    out=set()
    for f in app.get('globalFlags') or []:
        if f.get('long'): out.add(f['long'])
    for sc in app.get('subcommands') or []:
        for f in sc.get('flags') or []:
            if f.get('long'): out.add(f['long'])
    return out
errors=[]
for app in spec.get('apps') or []:
    name=app.get('name')
    if not name: continue
    hp=help_path(name)
    if not hp.exists():
        errors.append(f'{name}: help source not found: {hp}'); continue
    r=subprocess.run(['bash', str(hp), '--help'], capture_output=True, text=True)
    text=(r.stdout or '')+'\n'+(r.stderr or '')
    hf=extract_long_flags(text); sf=spec_flags(app)
    for flag in sorted(hf-sf): errors.append(f'{name}: help flag {flag} missing from spec')
    for flag in sorted(sf-hf): errors.append(f'{name}: spec flag {flag} missing from help')
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
