Register-Step -Id "lockfile-validation" -Name "Lockfile validation" -Action {
  param([Parameter(Mandatory)][PSObject]$Context)

  $HasArgs = $Context.HasArgs
  $RepoRoot = $Context.RepoRoot
  $PositionalArgs = $Context.PositionalArgs

  $r = if ($RepoRoot) { $RepoRoot } else { Split-Path -Parent (Split-Path -Parent $PSScriptRoot) }

  # Skip when scoped to files outside this step's scope (no lockfile JSON files).
  if ($HasArgs) {
    $hasLfFiles = @($PositionalArgs | Where-Object { $_ -match '(lockfile|lifecycle-allowlist)\.json$' }).Count -gt 0
    if (-not $hasLfFiles) {
      Skip-Step -Number (Get-StepNumber) -Name "Lockfile validation" -Reason "no lockfile files to check"
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
    $lfOverlapExceptions = @()  # ref: allow-and-deny-lists.instructions.md#D1 -- legitimate cross-section overlaps in lockfile
    $pkgToSections = @{}
    foreach ($section in $lf.Keys) {
      if ($section -eq 'ollama') { continue }
      if ($section -eq 'suggestions') {
        # Scan nested suggestions sections (homebrew.masApps, cursor, vscode)
        foreach ($sub in $lf['suggestions'].Keys) {
          if ($lf['suggestions'][$sub] -is [hashtable]) {
            foreach ($pkg in $lf['suggestions'][$sub].Keys) {
              $subKey = "suggestions.$sub"
              if ($pkgToSections.ContainsKey($pkg)) {
                $pkgToSections[$pkg] += , $subKey
              } else {
                $pkgToSections[$pkg] = @($subKey)
              }
            }
          }
        }
      } elseif ($lf[$section] -is [hashtable]) {
        foreach ($pkg in $lf[$section].Keys) {
          if ($pkgToSections.ContainsKey($pkg)) {
            $pkgToSections[$pkg] += , $section
          } else {
            $pkgToSections[$pkg] = @($section)
          }
        }
      }
    }
    # Cursor and VS Code are both VS Code–based editors; identical extension IDs
    # across these two sections are expected and excluded from overlap checks.
    # Root cursor/vscode sections (editor plugins) also overlap with suggestions pairs.
    $vscodeBased = @('suggestions.cursor', 'suggestions.vscode', 'cursor', 'vscode')
    foreach ($entry in $pkgToSections.GetEnumerator()) {
      if ($entry.Value.Count -gt 1 -and $entry.Key -notin $lfOverlapExceptions) {
        $nonVscode = $entry.Value | Where-Object { $_ -notin $vscodeBased }
        if ($nonVscode.Count -gt 0) {
          Write-ErrorMessage "package '$($entry.Key)' appears in both $($entry.Value -join ', ')"
          $lfOverlapErrors++
        }
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

  # Section validation (non-empty, no placeholders) is enforced by
  # lockfile.schema.json via step 07 (schema-validation). This step
  # only handles cross-section overlap and lifecycle-allowlist checks.

  Write-Message "lockfile.json validation passed"
  return $true
}
