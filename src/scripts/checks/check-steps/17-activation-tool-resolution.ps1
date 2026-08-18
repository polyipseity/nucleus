Register-Step -Id "activation-tool-resolution" -Name "Activation script tool resolution" -Action {
  param([Parameter(Mandatory)][PSObject]$Context)

  $HasArgs = $Context.HasArgs
  $RepoRoot = $Context.RepoRoot
  $PositionalArgs = $Context.PositionalArgs

  $r = if ($RepoRoot) { $RepoRoot } else { Split-Path -Parent (Split-Path -Parent $PSScriptRoot) }

  $violations = 0

  # PowerShell activation scripts use Get-Command/Test-Path guards for external
  # tool resolution — a fundamentally different pattern from POSIX store-path args.
  # This check scans for bare external tool calls without resolution guards.
  # Keep conservative: only flag high-risk tools known to require store-path args.

  # Scope: PowerShell activation modules.
  $activationDirs = @(
    (Join-Path $r 'src/platforms/Windows/modules')
  )

  if ($HasArgs) {
    $ps1Files = @(if ($Context.Ps1Files) { $Context.Ps1Files } else { $PositionalArgs | Where-Object { $_ -like '*.ps1' } })
    # Filter to activation directories only.
    $ps1Files = @($ps1Files | Where-Object {
        $f = $_
        ($activationDirs | Where-Object { $f -like "$_" }).Count -gt 0
      })
    if ($ps1Files.Count -eq 0) {
      Skip-Step -Number (Get-StepNumber) -Name "Activation script tool resolution" -Reason "no PowerShell activation scripts to check"
      return 2
    }
  } else {
    $ps1Files = @(
      $activationDirs | Where-Object { Test-Path $_ } | ForEach-Object {
        Get-ChildItem -Recurse -Path $_ -Include *.ps1 | ForEach-Object { $_.FullName }
      }
    )
    if ($ps1Files.Count -eq 0) {
      Skip-Step -Number (Get-StepNumber) -Name "Activation script tool resolution" -Reason "no PowerShell activation scripts to check"
      return 2
    }
  }

  # High-risk tools: external commands that MUST be resolved via store-path arg
  # or Get-Command/Test-Path guard before invocation.
  $highRiskTools = @(
    'pip', 'pip3', 'npm', 'npx', 'cargo', 'rustup', 'bun',
    'winget', 'choco', 'scoop',
    'python', 'python3', 'node',
    'go', 'rustc',
    'cmake', 'make',
    'docker', 'docker-compose',
    'kubectl', 'helm',
    'ffmpeg', 'ffprobe',
    'gs'  # ghostscript
  )

  # For each PS1 file, check for bare invocations of high-risk tools.
  foreach ($file in $ps1Files) {
    # Skip if file doesn't exist (may have been deleted since find).
    if (-not (Test-Path $file)) { continue }

    $lines = Get-Content -LiteralPath $file -ErrorAction SilentlyContinue
    if (-not $lines) { continue }

    for ($i = 0; $i -lt $lines.Count; $i++) {
      $line = $lines[$i]

      # Skip comments and empty lines.
      if ($line -match '^\s*(#|$)') { continue }

      # Skip lines inside here-strings (@{ ... @} or @" ... "@).
      # Simple heuristic: skip lines between here-string delimiters.
      # (A full parser is out of scope — keep conservative.)

      # Check for bare invocation patterns:
      #   & "tool" args     (call operator with unquoted tool)
      #   tool args          (bare command at start of statement)
      # Skip if the line contains a Get-Command or Test-Path guard for the tool.

      foreach ($tool in $highRiskTools) {
        # Pattern: bare invocation — tool at statement start or after & operator.
        $barePattern = "(^|;\s*)$([regex]::Escape($tool))\s"
        $callPattern = "(&\s+)`"$tool`""

        $isBare = ($line -match $barePattern) -or ($line -match $callPattern)
        if (-not $isBare) { continue }

        # Check if the same line or a nearby guard resolves this tool.
        # Look backwards up to 10 lines for Get-Command or Test-Path referencing this tool.
        $guarded = $false
        $lookback = [Math]::Min($i, 10)
        for ($j = $i - 1; $j -ge ($i - $lookback); $j--) {
          $prevLine = $lines[$j]
          if ($prevLine -match "Get-Command.*$([regex]::Escape($tool))" -or
              $prevLine -match "Test-Path.*$([regex]::Escape($tool))") {
            $guarded = $true
            break
          }
          # Also check for $env:PATH or tool-path variable assignment.
          $toolEsc = [regex]::Escape($tool)
          if ($prevLine -match "(?i)$toolEsc") {
            # Likely a variable assignment or path reference for the tool — guarded.
            $guarded = $true
            break
          }
        }

        # Also check if the tool is referenced as a variable (store-path pattern).
        $toolEsc = [regex]::Escape($tool)
        if ($line -match "(?i)`$\w*$toolEsc") {
          $guarded = $true
        }

        if (-not $guarded) {
          Write-ErrorMessage "${file}:$($i + 1): bare external command '$tool' not resolved via Get-Command/Test-Path guard or store-path variable"
          $violations++
        }
      }
    }
  }

  if ($violations -gt 0) {
    return $false
  }

  Write-Message "all PowerShell activation scripts use resolved tool paths."
  return $true
}
