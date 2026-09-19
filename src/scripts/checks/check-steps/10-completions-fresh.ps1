# Step 10: autocompletion freshness (PowerShell).
#
# Verifies that the generated completer flag inventory in profile.ps1 matches
# src/scripts/completions/gen-completions.ps1 (drift), that every nucleus-* command has both a
# zsh _nucleus-<cmd> file and a pwsh completer entry with a defined flag
# inventory (coverage), that every flag inventory the profile references is
# defined in it (referenced-vs-defined), and that the -Sections value completion
# in the bump-lockfile completer still has its --list-sections contract
# (introspection).

Register-Step -Id "completions-fresh" -Name "Autocompletion freshness" -Action {
  param([Parameter(Mandatory)][PSObject]$Context)

  $RepoRoot = $Context.RepoRoot

  $r = if ($RepoRoot) { $RepoRoot } else { Split-Path -Parent (Split-Path -Parent $PSScriptRoot) }

  # 1. Drift: the generated inventory must match src/scripts/completions/gen-completions.ps1.
  Write-Message "--- generated completer inventory matches generator ---"
  & (Join-Path $r 'src\scripts\completions\gen-completions.ps1') -Check
  if ($LASTEXITCODE -ne 0) {
    Write-ErrorMessage "src/scripts/shell/profile.ps1 is stale -- run src/scripts/completions/gen-completions.ps1"
    return $false
  }

  # 2. Coverage: every nucleus-* command needs a zsh _nucleus-<cmd> file, a pwsh
  #    Register-ArgumentCompleter entry, and a DEFINED $nucleus<Cmd>Flags array.
  Write-Message "--- coverage: zsh + pwsh completions for every nucleus-* command ---"
  $commands = @(
    'ai', 'apply', 'bootstrap', 'check', 'cloud', 'config', 'gc',
    'utils', 'svc', 'test', 'update', 'vm'
  )
  $profilePath = Join-Path $r 'src/scripts/shell/profile.ps1'
  $zshDir = Join-Path $r 'src/modules/completions/zsh'
  $profileText = [System.IO.File]::ReadAllText($profilePath)
  $missing = @()
  foreach ($command in $commands) {
    $pascal = (($command.Split('-') | ForEach-Object { $_.Substring(0, 1).ToUpperInvariant() + $_.Substring(1) }) -join '')
    $hasZsh = Test-Path -Path (Join-Path $zshDir "_nucleus-$command") -PathType Leaf
    # WHY: match the registration at the line start, so a mention inside a comment
    # or another command's name (nucleus-svc vs nucleus-service-watchdog) cannot
    # stand in for a real completer entry.
    $hasCompleter = [regex]::IsMatch($profileText, "(?m)^Register-ArgumentCompleter -CommandName nucleus-$command\s")
    # WHY: anchored to the line start with '=', i.e. the definition. The completer
    # body mentions the same variable, so a name-anywhere match stayed green while
    # nothing defined it -- that is how the missing utils inventory shipped.
    $hasFlagVar = [regex]::IsMatch($profileText, "(?m)^\`$nucleus${pascal}Flags\s*=")
    if (-not ($hasZsh -and $hasCompleter -and $hasFlagVar)) {
      $missing += "$command (zsh:$hasZsh completer:$hasCompleter flagvar:$hasFlagVar)"
    }
  }
  if ($missing.Count -gt 0) {
    Write-ErrorMessage "completions missing for: $($missing -join ', ')"
    return $false
  }

  # 2b. Every flag inventory the profile REFERENCES must be DEFINED in it. The
  #     generated region is the only definition site, so a completer naming a
  #     variable the generator no longer emits completes nothing at all.
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

  # 3. Introspection contract: the update lockfile completer completes -Sections
  #    values via scripts/update.sh -ListSections; that parameter must exist.
  Write-Message "--- --list-* introspection contract ---"
  $updatePath = Join-Path $r 'scripts\update.sh'
  if (-not (Select-String -Path $updatePath -Pattern 'list-sections' -SimpleMatch -Quiet)) {
    Write-ErrorMessage "scripts/update.sh lacks --list-sections, which the update lockfile completer depends on"
    return $false
  }

  Write-Message "completions are fresh."
  return $true
}
