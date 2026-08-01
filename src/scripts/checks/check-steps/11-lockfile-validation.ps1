Register-Step -Id "lockfile-validation" -Number 11 -Name "Lockfile validation" -Action {
  param($HasArgs, $RepoRoot, $PositionalArgs)

  $r = if ($RepoRoot) { $RepoRoot } else { Split-Path -Parent (Split-Path -Parent $PSScriptRoot) }

  # Skip when scoped to files outside this step's scope (no lockfile JSON files).
  if ($HasArgs) {
    $hasLfFiles = @($PositionalArgs | Where-Object { $_ -match '(lockfile|lifecycle-allowlist)\.json$' }).Count -gt 0
    if (-not $hasLfFiles) {
      Write-Message "==== 11: Lockfile validation ==== SKIPPED (no lockfile files to check)"
      return 2
    }
  }

  # --- Consistency and overlap checks ---
  $lfPath = Join-Path $r "src\lockfiles\lockfile.json"
  $lf = $null
  $lfOverlapErrors = 0

  if (-not (Test-Path $lfPath)) {
    Write-ErrorMessage "lockfile.json not found at $lfPath"
    $lfOverlapErrors++
  } else {
    $lf = Get-Content $lfPath -Raw | ConvertFrom-Json -AsHashtable
    # Known cross-section overlaps that are legitimate
    $lfOverlapExceptions = @('astral-sh.ty')  # ref: allow-and-deny-lists.instructions.md#D1 -- legitimate cross-section overlap in lockfile
    $pkgToSections = @{}
    foreach ($section in $lf.Keys) {
      if ($section -eq 'ollama') { continue }
      if ($lf[$section] -is [hashtable]) {
        foreach ($pkg in $lf[$section].Keys) {
          if ($pkgToSections.ContainsKey($pkg)) {
            $pkgToSections[$pkg] += , $section
          } else {
            $pkgToSections[$pkg] = @($section)
          }
        }
      }
    }
    foreach ($entry in $pkgToSections.GetEnumerator()) {
      if ($entry.Value.Count -gt 1 -and $entry.Key -notin $lfOverlapExceptions) {
        Write-ErrorMessage "package '$($entry.Key)' appears in both $($entry.Value -join ', ')"
        $lfOverlapErrors++
      }
    }
    # Self-pruning: check if lfOverlapExceptions are still needed (A4)
    foreach ($exception in $lfOverlapExceptions) {
      if ($pkgToSections.ContainsKey($exception)) {
        if ($pkgToSections[$exception].Count -le 1) {
          Write-ErrorMessage "stale exception: '$exception' no longer overlaps sections — remove from lfOverlapExceptions"
          $lfOverlapErrors++
        }
      } else {
        Write-ErrorMessage "stale exception: '$exception' is not present in any lockfile section — remove from lfOverlapExceptions"
        $lfOverlapErrors++
      }
    }
  }

  if ($lfOverlapErrors -gt 0) {
    Write-ErrorMessage "lockfile.json consistency: $lfOverlapErrors overlap issue(s)"
    return $false
  }
  Write-Message "lockfile.json consistency: no overlapping packages across sections"

  # --- Lifecycle script allowlist validation ---
  $lfAlPath = Join-Path $r "src\lockfiles\lifecycle-allowlist.json"
  $lfAlErrors = 0
  if (-not (Test-Path $lfAlPath)) {
    Write-ErrorMessage "lifecycle-allowlist.json not found at $lfAlPath"
    $lfAlErrors++
  } else {
    $lfAlRaw = Get-Content $lfAlPath -Raw -ErrorAction Stop
    $lfAl = $null
    try {
      $lfAl = ConvertFrom-Json $lfAlRaw -AsHashtable
    } catch {
      Write-ErrorMessage "lifecycle-allowlist.json is not valid JSON: $($_.Exception.Message)"
      $lfAlErrors++
    }
    if ($null -ne $lfAl -and $lfAl -isnot [hashtable]) {
      Write-ErrorMessage "lifecycle-allowlist.json must be a JSON object"
      $lfAlErrors++
    } elseif ($null -ne $lfAl) {
      foreach ($entry in $lfAl.GetEnumerator()) {
        if ($entry.Value -isnot [string] -or [string]::IsNullOrEmpty($entry.Value)) {
          Write-ErrorMessage "lifecycle-allowlist.json: '$($entry.Key)' has empty or non-string justification"
          $lfAlErrors++
        }
      }
    }
  }

  if ($lfAlErrors -gt 0) {
    Write-ErrorMessage "lifecycle-allowlist.json validation failed with $lfAlErrors error(s)"
    return $false
  }
  $lfAlCount = if ($null -ne $lfAl -and $lfAl -is [hashtable]) { $lfAl.Count } else { 0 }
  Write-Message "lifecycle-allowlist.json: valid (entry count: $lfAlCount)"

  # --- Lockfile section validation ---
  if ($null -eq $lf) {
    Write-ErrorMessage "lockfile.json could not be loaded -- skipping section validation"
    return $false
  }

  $lfErrors = 0

  # Check sections that must be non-empty
  foreach ($section in @('scoop', 'cargo-binstall', 'bun', 'uv', 'rustup', 'pwsh')) {
    if (-not $lf.ContainsKey($section) -or $lf[$section].Count -eq 0) {
      Write-ErrorMessage "${section}: empty or missing section"
      $lfErrors++
    } else {
      foreach ($entry in $lf[$section].GetEnumerator()) {
        if ([string]::IsNullOrEmpty($entry.Value) -or @('CHANGEME', '1.0.0') -contains $entry.Value) {
          Write-ErrorMessage "${section}.$($entry.Key): placeholder version ($($entry.Value))"
          $lfErrors++
        }
      }
    }
  }

  # winget: warn if empty
  if (-not $lf.ContainsKey('winget')) {
    Write-ErrorMessage "winget: missing section"
    $lfErrors++
  } elseif ($lf.winget.Count -gt 0) {
    foreach ($entry in $lf.winget.GetEnumerator()) {
      if ([string]::IsNullOrEmpty($entry.Value) -or @('CHANGEME', '1.0.0') -contains $entry.Value) {
        Write-ErrorMessage "winget.$($entry.Key): placeholder version ($($entry.Value))"
        $lfErrors++
      }
    }
  } else {
    Write-Message "warning: winget: empty section (not yet populated)"
  }

  # vscode: warn if empty
  if (-not $lf.ContainsKey('vscode')) {
    Write-ErrorMessage "vscode: missing section"
    $lfErrors++
  } elseif ($lf.vscode.Count -gt 0) {
    foreach ($entry in $lf.vscode.GetEnumerator()) {
      if ([string]::IsNullOrEmpty($entry.Value) -or @('CHANGEME', '1.0.0') -contains $entry.Value) {
        Write-ErrorMessage "vscode.$($entry.Key): placeholder version ($($entry.Value))"
        $lfErrors++
      }
    }
  } else {
    Write-Message "warning: vscode: empty section (not yet populated)"
  }

  # homebrew: must be non-empty
  if (-not $lf.ContainsKey('homebrew') -or $lf.homebrew.Count -eq 0) {
    Write-ErrorMessage "homebrew: empty or missing section"
    $lfErrors++
  }

  # ollama: must have at least one profile with models
  if (-not $lf.ContainsKey('ollama') -or $lf.ollama.Count -eq 0) {
    Write-ErrorMessage "ollama: empty or missing section"
    $lfErrors++
  } else {
    foreach ($ollamaProfile in $lf.ollama.GetEnumerator()) {
      if ($ollamaProfile.Value.Count -eq 0) {
        Write-ErrorMessage "ollama.$($ollamaProfile.Key): empty model list"
        $lfErrors++
      } else {
        for ($i = 0; $i -lt $ollamaProfile.Value.Count; $i++) {
          $model = $ollamaProfile.Value[$i]
          if ([string]::IsNullOrEmpty($model.name) -or [string]::IsNullOrEmpty($model.tag)) {
            Write-ErrorMessage "ollama.$($profile.Key)[$i]: missing name or tag"
            $lfErrors++
          }
        }
      }
    }
  }

  if ($lfErrors -gt 0) {
    Write-ErrorMessage "lockfile.json validation failed with $lfErrors error(s)"
    return $false
  }

  Write-Message "lockfile.json validation passed"
  return $true
}
