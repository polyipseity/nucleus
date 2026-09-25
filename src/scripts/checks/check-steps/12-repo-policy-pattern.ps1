Register-Step -Id "repo-policy-pattern" -Name "Repository policy (pattern-based)" -Action {
  param([Parameter(Mandatory)][PSObject]$Context)

  $HasArgs = $Context.HasArgs
  $RepoRoot = $Context.RepoRoot
  $PositionalArgs = $Context.PositionalArgs

  $r = if ($RepoRoot) { $RepoRoot } else { Split-Path -Parent (Split-Path -Parent $PSScriptRoot) }
  $selfLeaf = if ($PSCommandPath) { Split-Path -Leaf $PSCommandPath } else { '12-repo-policy-pattern.ps1' }
  # WHY: the .sh twin carries the same literal pattern text and must be excluded from scans too
  $selfShLeaf = $selfLeaf -replace '\.ps1$', '.sh'
  # WHY: all repo-policy step files must be excluded from pattern scans to avoid self-referencing literal pattern text
  $allStepLeaves = @('11-repo-policy-grep.ps1', '12-repo-policy-pattern.ps1', '13-repo-policy-data.ps1', '14-repository-policy.ps1')
  $allStepShLeaves = @('11-repo-policy-grep.sh', '12-repo-policy-pattern.sh', '13-repo-policy-data.sh', '14-repository-policy.sh')
  $failed = $false

  Write-Message "--- config method compliance ---"

  $cfgDir = Join-Path -Path $r -ChildPath "src\modules\configs"
  $cfgErrors = 0

  # Single-pass: collect all config file basenames, run one Select-String across src/
  $cfgFiles = Get-ChildItem -Path $cfgDir -Recurse -File
  $srcFiles = Get-ChildItem -Path (Join-Path $r "src") -Recurse -Include '*.nix', '*.ps1', '*.sh' |
    Where-Object { $_.FullName -notmatch '[\/]vendor[\/]' -and $_.FullName -notmatch '[\/]configs[\/]' } |
    Select-GitIgnored  # ref: allow-and-deny-lists.instructions.md#B1 -- structural invariants; vendored code and config methods are different concerns; gitignore filter applied on top
  # WHY: raw basenames with -SimpleMatch mirror the .sh twin's grep -F -f semantics; [regex]::Escape here would make dotted basenames (e.g. system.gitconfig) match literally and never be found
  $cfgPatterns = @($cfgFiles | ForEach-Object { $_.Name } | Sort-Object -Unique)
  # WHY: Select-GitIgnored returns path strings; piping strings to Select-String searches them as content, so -Path is required to read the actual files
  $cfgSelectOutput = Select-String -Path $srcFiles -Pattern $cfgPatterns -SimpleMatch
  # Single-pass: collect all check-suppress:config-method lines for preceding-line checking
  $cfgMethodOutput = Select-String -Path $srcFiles -Pattern '# check-suppress:config-method'
  # WHY: refs may use a ${hostName} template (e.g. git/${hostName}.gitconfig) that no
  # raw basename substring-matches; gather those lines for per-file resolution below.
  $cfgTemplateOutput = Select-String -Path $srcFiles -Pattern '${hostName}' -SimpleMatch

  $parallelJobs = [Environment]::ProcessorCount

  # WHY: $using: is only valid inside the -Parallel scriptblock; -ThrottleLimit is
  # evaluated in the caller scope, so it takes the plain variable (canonical order:
  # scriptblock first, then -ThrottleLimit)
  $cfgFileErrors = $cfgFiles | ForEach-Object -Parallel {
    $basename = $_.Name

    # Skip infrastructure files and Nix modules inside configs/  # ref: allow-and-deny-lists.instructions.md#A2 -- infrastructure files are not configs
    if ($basename -in '.gitkeep', '.gitignore') { return $null }
    if ($basename -like '*.schema.json') { return $null }
    # Skip Nix module files — imported as modules (e.g. `import ./configs/qtpass {}`), not deployed as config files. The import references the directory, not the file; basename `default.nix` matches hundreds of unrelated references.
    if ($basename -like '*.nix') { return $null }

    # Skip agent customization files (consumed as a directory via Method 4)  # ref: allow-and-deny-lists.instructions.md#A2 -- agents/* consumed as directory
    $relPath = $_.FullName.Substring($using:cfgDir.Length + 1) -replace '\\', '/'
    if ($relPath -like 'agents/*') { return $null }

    # Skip configs deployed via provision-data-directory or flake inputs (not direct src/ references)
    # ref: allow-and-deny-lists.instructions.md#A2 -- non-standard deployment mechanisms
    if ($relPath -in 'hermes-agent/SOUL.md', 'ollama/models.json') { return $null }

    # Check against cached Select-String output -- relative path first, then basename
    $refs = @($using:cfgSelectOutput | Where-Object { $_.Line -match [regex]::Escape($relPath) })
    if ($refs.Count -eq 0) {
      $refs = @($using:cfgSelectOutput | Where-Object { $_.Line -match [regex]::Escape($basename) })
    }
    if ($refs.Count -eq 0) {
      # check-suppress:config-method: self-reference -- this is the step's own explanatory comment, not a config deployment
      # WHY: ${hostName}.gitconfig references every host's config (MacBook/NixOS/Windows.gitconfig);
      # match template lines by the basename's extension suffix.
      $dotIndex = $basename.IndexOf('.')
      if ($dotIndex -gt 0) {
        $templateSuffix = [regex]::Escape($basename.Substring($dotIndex))
        $refs = @($using:cfgTemplateOutput | Where-Object { $_.Line -match ('\$\{hostName\}' + $templateSuffix) })
      }
    }

    if ($refs.Count -eq 0) {
      return "$relPath : no references found in src/ (excluding configs/) -- orphaned config?"
    }

    $hasMethod = $false
    foreach ($ref in $refs) {
      if ($ref.Line -match '# check-suppress:config-method') {
        $hasMethod = $true
        break
      }
      # Check up to 5 preceding lines for the annotation (comment blocks may span multiple lines)
      if ($ref.LineNumber -gt 1) {
        $searchLimit = [Math]::Max(1, $ref.LineNumber - 10)
        for ($pn = $ref.LineNumber - 1; $pn -ge $searchLimit; $pn--) {
          $prevMatch = $using:cfgMethodOutput | Where-Object { $_.Path -eq $ref.Path -and $_.LineNumber -eq $pn }
          if ($prevMatch) {
            $hasMethod = $true
            break
          }
        }
        if ($hasMethod) { break }
      }
    }
    if (-not $hasMethod) {
      return "$relPath : referenced but no '# check-suppress:config-method' comment found on or before reference lines"
    }

    return $null
  } -ThrottleLimit $parallelJobs

  foreach ($cfe in $cfgFileErrors) {
    if ($cfe) {
      Write-ErrorMessage $cfe
      $cfgErrors++
    }
  }

  if ($cfgErrors -gt 0) {
    Write-ErrorMessage "config method compliance check failed with $cfgErrors error(s)"
    $failed = $true
  } else {
    Write-Message "config method compliance passed."
  }

  Write-Message "--- activation naming policy ---"

  # Collect activation entry definitions as "file:line:name" lines across the three
  # namespaces (home.activation, system.activationScripts, nucleus.terminalActivations).
  $nsRegex = '(home\.activation|system\.activationScripts|nucleus\.terminalActivations)'
  # Attrset entry lines: name[.sub] = <lib.* value> or name[.sub] = (value on next line).
  # Nested-content lines (config = {, Unit = {, bundle_id = "...") never match.
  # WHY: group 1 captures the entry name (mirrors the .sh sed s/^[[:space:]]*([a-zA-Z0-9_-]+).*/\1/); group 2 is the optional .sub suffix and must not be used for the name
  $entryRegex = '^\s*([a-zA-Z0-9_-]+)(\.[a-zA-Z0-9_-]+)?\s*=\s*(lib\.(mkIf|mkAfter|mkBefore|mkForce|mkOverride|mkOrder|hm\.dag\.entry(A|Before|Order|After))|\s*$)'
  $dottedRegex = '([^a-zA-Z0-9_.]|^)(home\.activation|system\.activationScripts|nucleus\.terminalActivations)\.[a-zA-Z0-9_-]+'
  # -cmatch: the kebab regex is anchored on [a-z] and must stay case-sensitive.
  $kebabRegex = '^[a-z][a-z0-9]*(-[a-z0-9]+)*$'
  $macosDirRegex = '^(src[\\/]platforms[\\/]macOS[\\/]|src[\\/]hosts[\\/]MacBook[\\/])'
  $namingErrors = 0
  $definitions = @()

  # WHY: if-expression output is pipeline-enumerated — an empty branch yields $null, crashing the .Count check below under StrictMode; the @() wrapper forces an array
  # WHY: paths are made repo-relative (mirroring the .sh twin's `find src` output) so the ^src/... anchor in $macosDirRegex matches; full paths would never match and silently disable the macos- prefix rule
  $nixFiles = @(if ($HasArgs) {
    if ($Context.NixFiles) { $Context.NixFiles } else { @($PositionalArgs | Where-Object { $_ -like 'src/*.nix' }) }
  } else {
    @(Get-ChildItem -Recurse -Path (Join-Path $r 'src') -Include '*.nix' |
        Where-Object { $_.FullName -notmatch '[\\/]vendor[\\/]' } |
        ForEach-Object { [IO.Path]::GetRelativePath($r, $_.FullName) } |
        Select-GitIgnored)  # ref: allow-and-deny-lists.instructions.md#B6 -- structural invariant; gitignore filter applied on top
  })

  if ($nixFiles.Count -gt 0) {
    foreach ($file in $nixFiles) {
      $lines = @(Get-Content -Path $file)
      $inBlock = $false
      $depth = 0
      for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        if ($line -match '^\s*#') { continue }

        # Dotted definitions: home.activation.<name> = ...
        if ($line -match $dottedRegex) {
          $definitions += "$file`:$($i + 1):$(($Matches[0] -split '\.')[-1])"
        }

        # Attrset definitions: <ns> = { <name> = ...; }; regions
        if (-not $inBlock -and $line -match ($nsRegex + '\s*=[^;]*\{')) {
          $inBlock = $true
          $depth = 0
        }
        if ($inBlock -and $line -match $entryRegex) {
          $definitions += "$file`:$($i + 1):$($Matches[1])"
        }
        if ($inBlock) {
          $depth += ([regex]::Matches($line, '\{')).Count - ([regex]::Matches($line, '\}')).Count
          if ($depth -le 0) { $inBlock = $false; $depth = 0 }
        }
      }
    }
  }
  $definitions = @($definitions | Sort-Object -Unique)

  # Names defined outside macOS-scoped paths are cross-platform and need no macos- prefix.
  $sharedNames = @($definitions | Where-Object { $_ -notmatch $macosDirRegex } | ForEach-Object { ($_ -split ':')[-1] } | Sort-Object -Unique)

  foreach ($def in $definitions) {
    $parts = $def -split ':'
    $file = $parts[0]
    $lineNum = $parts[1]
    $name = $parts[2]

    # Exempt classes: framework-generated and hardcoded names (see
    # activation-scripts.instructions.md: Exempt classes).
    if ($name -in @('linkGeneration', 'writeBoundary', 'checkLinkTargets', 'setupLaunchAgents', 'installPackages', 'preActivation', 'extraActivation', 'postActivation')) { continue }
    if ($name -like 'unprotectSymlink_*' -or $name -like 'protectSymlink_*' -or $name -like 'mergeConfig_*') { continue }
    if ($name -like '*sops*') { continue }

    if ($name -cnotmatch $kebabRegex) {
      Write-ErrorMessage "activation name '$name' at $file`:$lineNum is not kebab-case (see .agents/instructions/activation-scripts.instructions.md)"
      $namingErrors++
    }
    if ($name -like 'nucleus-*') {
      Write-ErrorMessage "activation name '$name' at $file`:$lineNum uses the forbidden nucleus- prefix (see .agents/instructions/activation-scripts.instructions.md)"
      $namingErrors++
    }
    if ($file -match $macosDirRegex -and $name -notlike 'macos-*' -and $sharedNames -notcontains $name) {
      Write-ErrorMessage "macOS-only activation name '$name' at $file`:$lineNum lacks the macos- prefix (see .agents/instructions/activation-scripts.instructions.md)"
      $namingErrors++
    }
  }

  if ($namingErrors -gt 0) {
    Write-ErrorMessage "activation naming policy check failed with $namingErrors error(s)"
    $failed = $true
  } else {
    Write-Message "activation naming policy passed."
  }

  Write-Message "--- logging format policy ---"

  $lfErrors = 0
  # Exclude this check's own files: their source contains the literal pattern text.
  # ref: allow-and-deny-lists.instructions.md#C5 -- self-refs are dynamic
  $lfSelfLeaf = $selfLeaf
  $lfSelfShLeaf = $selfShLeaf

  # Logging-format policy scope: tracked script files outside vendored code,
  # secrets, and test fixtures (fixtures deliberately hold violation samples).
  # ref: allow-and-deny-lists.instructions.md#B6 -- structural invariants; vendored and secret files are separate concerns
  $lfFiles = @(if ($HasArgs) {
    @($PositionalArgs | Where-Object {
        $_ -notmatch '(^|[\\/])(vendor[\\/]|src[\\/]secrets[\\/]|tests[\\/]fixtures[\\/])' -and
        $_ -match '\.(sh|zsh|ps1|psm1)$' -and
        (Split-Path -Leaf $_) -notin @($lfSelfLeaf, $lfSelfShLeaf) + $allStepLeaves
      })
  } else {
    @(git ls-files | Select-GitIgnored | Where-Object {
        $_ -notmatch '(^|[\\/])(vendor[\\/]|src[\\/]secrets[\\/]|tests[\\/]fixtures[\\/])' -and
        $_ -match '\.(sh|zsh|ps1|psm1)$' -and
        (Split-Path -Leaf $_) -notin @($lfSelfLeaf, $lfSelfShLeaf) + $allStepLeaves
      })  # ref: allow-and-deny-lists.instructions.md#B6 -- structural invariant; gitignore filter applied on top
  })

  if ($lfFiles.Count -gt 0) {
    # Allowlist: the shared color helpers, their tests, and the log sanitizer
    # are the only sanctioned ANSI emitters. WHY: Invoke-LogManagement.ps1 is
    # the log sanitizer (it must reference ESC patterns to strip them) and its
    # tests feed ESC input, so both join the allowlist alongside the helper
    # modules and their tests.
    $lfAllowlisted = @('lib.sh', 'step-runner.sh', 'step-runner.ps1', 'test-lib.sh', 'test-lib.ps1',
      'Format-NucleusOutput.psm1', 'Format-NucleusOutput.Tests.ps1', 'Invoke-LogManagement.ps1', 'log-management.Tests.ps1')
    $lfScanned = @($lfFiles | Where-Object { (Split-Path -Leaf $_) -notin $lfAllowlisted })

    $lfShFiles = @($lfScanned | Where-Object { $_ -match '\.(sh|zsh)$' })
    $lfEchoFiles = @($lfScanned | Where-Object { $_ -match '\.sh$' })
    $lfPsFiles = @($lfScanned | Where-Object { $_ -match '\.(ps1|psm1)$' })

    if ($lfShFiles.Count -gt 0) {
      foreach ($m in (Select-String -Path $lfShFiles -Pattern '\\033\[', '\\e\[', '\\x1b\[')) {
        Write-ErrorMessage "$($m.Path):$($m.LineNumber): raw ANSI escape literal (use shared color helpers)"
        $lfErrors++
      }
      foreach ($m in (Select-String -Path $lfShFiles -Pattern '\btput\b')) {
        Write-ErrorMessage "$($m.Path):$($m.LineNumber): terminal capability query (use shared color helpers)"
        $lfErrors++
      }
    }
    if ($lfEchoFiles.Count -gt 0) {
      foreach ($m in (Select-String -Path $lfEchoFiles -Pattern '(^|[^A-Za-z0-9_])echo\s+-e([^A-Za-z0-9_]|$)')) {
        Write-ErrorMessage "$($m.Path):$($m.LineNumber): echo dash-e flag (use printf with %b)"
        $lfErrors++
      }
    }
    if ($lfPsFiles.Count -gt 0) {
      foreach ($m in (Select-String -Path $lfPsFiles -Pattern '\\033\[', '\\e\[', '\\x1b\[')) {
        Write-ErrorMessage "$($m.Path):$($m.LineNumber): raw ANSI escape literal (use shared color helpers)"
        $lfErrors++
      }
      foreach ($m in (Select-String -Path $lfPsFiles -Pattern '\btput\b')) {
        Write-ErrorMessage "$($m.Path):$($m.LineNumber): terminal capability query (use shared color helpers)"
        $lfErrors++
      }
      foreach ($m in (Select-String -Path $lfPsFiles -Pattern '\[char\]27')) {
        Write-ErrorMessage "$($m.Path):$($m.LineNumber): char-27 escape literal (use PSStyle helpers)"
        $lfErrors++
      }
      # WHY: -CaseSensitive matches the awk twin (repository-policy.awk), whose
      # regex is case-sensitive by construction. Without it, Select-String's
      # case-insensitive default flags any lowercase-e example, including a
      # comment that names the automatic Event variable.
      foreach ($m in (Select-String -Path $lfPsFiles -Pattern '`e' -CaseSensitive)) {
        Write-ErrorMessage "$($m.Path):$($m.LineNumber): backtick-e escape literal (use PSStyle helpers)"
        $lfErrors++
      }
    }
  }

  # Self-check: the color spec requires NO_COLOR handling in both shared helpers.
  # Guarded on existence so fixture trees in tests skip this content probe.
  $libShPath = Join-Path $r 'src\scripts\lib\lib.sh'
  if ((Test-Path -LiteralPath $libShPath) -and -not (Select-String -Path $libShPath -Pattern 'NO_COLOR' -Quiet)) {
    Write-ErrorMessage "src/scripts/lib/lib.sh does not reference NO_COLOR (logging-format self-check)"
    $lfErrors++
  }
  $psm1Path = Join-Path $r 'src\platforms\Windows\modules\Format-NucleusOutput.psm1'
  if ((Test-Path -LiteralPath $psm1Path) -and -not (Select-String -Path $psm1Path -Pattern 'NO_COLOR' -Quiet)) {
    Write-ErrorMessage "src/platforms/Windows/modules/Format-NucleusOutput.psm1 does not reference NO_COLOR (logging-format self-check)"
    $lfErrors++
  }

  if ($lfErrors -gt 0) {
    Write-ErrorMessage "logging format policy check failed with $lfErrors error(s)"
    $failed = $true
  } else {
    Write-Message "logging format policy passed."
  }

  # --- removed skip mechanism ---
  # ref: step-runner.instructions.md -- declared applicability replaces step-level skipping
  Write-Message "--- removed skip mechanism ---"
  $skipErrors = 0
  # WHY: the runners document the declared-applicability contract, and
  # repository-policy.awk plus both gate steps carry the pattern list itself.
  $skipScopeExcluded = @('step-runner.sh', 'step-runner.ps1', 'repository-policy.awk', $selfLeaf, $selfShLeaf) + $allStepLeaves + $allStepShLeaves
  $skipConstructPattern = '\bskip_step\b|\bSkip-Step\b|\bInvoke-SkippedStep\b|--skip-steps|-SkipStep|\breturn[ \t]+2\b|\bSKIPPED\b|-SkipMessage|\bassert_skip\b|\bTESTS_SKIPPED\b'
  # WHY: if-expression output is pipeline-enumerated — an empty branch yields $null, crashing the .Count check below under StrictMode; the @() wrapper forces an array
  $skipFiles = @(if ($HasArgs) {
    @($PositionalArgs | Where-Object {
        $_ -match '^(src[\\/]scripts|scripts|tests)[\\/]' -and
        (Split-Path -Leaf $_) -notin $skipScopeExcluded -and
        (Test-Path -LiteralPath $_)
      })
  } else {
    @(git ls-files 'src/scripts' 'scripts' 'tests' | Select-GitIgnored | Where-Object {
        (Split-Path -Leaf $_) -notin $skipScopeExcluded -and
        (Test-Path -LiteralPath $_)
      })  # ref: allow-and-deny-lists.instructions.md#B6 -- structural invariant; gitignore filter applied on top
  })

  if ($skipFiles.Count -gt 0) {
    # WHY: -CaseSensitive mirrors the awk twin; without it Select-String's
    # case-insensitive default would flag prose that merely says "skipped".
    foreach ($m in (Select-String -Path $skipFiles -Pattern $skipConstructPattern -CaseSensitive)) {
      Write-ErrorMessage "$($m.Path):$($m.LineNumber): removed skip mechanism '$($m.Matches[0].Value)'; declare applicability at registration (-Platform/-Mode/-Requires)"
      $skipErrors++
    }
  }

  if ($skipErrors -gt 0) {
    Write-ErrorMessage "skip mechanism removal check failed with $skipErrors error(s)"
    $failed = $true
  } else {
    Write-Message "no removed skip mechanism found."
  }

  # --- nix file structure ---
  Write-Message "--- nix file structure ---"
  $nfsErrors = 0

  $nixSearchDirs = @(
    (Join-Path -Path $r -ChildPath 'src'),
    (Join-Path -Path $r -ChildPath 'tests')
  )
  $nixFiles = @()
  foreach ($dir in $nixSearchDirs) {
    if (Test-Path -LiteralPath $dir) {
      $nixFiles += Get-ChildItem -Path $dir -Recurse -Include '*.nix' |
        Where-Object { $_.FullName -notmatch '[\/](vendor)[\/]' } |
        Select-GitIgnored
    }
  }

  foreach ($f in $nixFiles) {
    $fullPath = $f  # WHY: $f is a string from Select-GitIgnored, not a FileInfo object
    # Pattern 1: <name>.nix alongside <name>/ directory
    $dirPath = [System.IO.Path]::ChangeExtension($fullPath, $null)
    if ($dirPath -and (Test-Path -LiteralPath $dirPath -PathType Container)) {
      Write-ErrorMessage "nix file structure: '$($fullPath.Substring($r.Length + 1))' exists alongside directory '$($dirPath.Substring($r.Length + 1))/' -- move to '$($dirPath.Substring($r.Length + 1))/default.nix' (nix-authoring.instructions.md)"
      $nfsErrors++
    }

    # Pattern 2: <name>/<name>.nix (should be default.nix)
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($fullPath)
    $parentName = Split-Path -Leaf (Split-Path -Parent $fullPath)
    if ($baseName -eq $parentName) {
      Write-ErrorMessage "nix file structure: '$($fullPath.Substring($r.Length + 1))' has same name as parent directory -- rename to 'default.nix' (nix-authoring.instructions.md)"
      $nfsErrors++
    }
  }

  if ($nfsErrors -gt 0) {
    Write-ErrorMessage "nix file structure check failed with $nfsErrors error(s)"
    $failed = $true
  } else {
    Write-Message "nix file structure passed."
  }

  # Service log-capture pair policy: a captured service stream always goes to its own
  # file, <dir>/stdout.log and <dir>/stderr.log (output-handling.instructions.md).
  # Merging the streams, capturing only one, and discarding one to /dev/null are all
  # prohibited, on every host.
  # WHY the narrow scope: this targets SERVICE capture points only -- launchd/systemd
  # capture directives and the wrappers that redirect a service's output. Ad-hoc
  # `2>$null`/`2>/dev/null` on a single command is the suppression-audit concern (step 14).
  Write-Message "--- log capture pair policy ---"
  $lcpErrors = 0
  $lcpSearchDirs = @(
    (Join-Path -Path $r -ChildPath 'src'),
    (Join-Path -Path $r -ChildPath 'tests')
  )
  $lcpFiles = @()
  foreach ($dir in $lcpSearchDirs) {
    if (Test-Path -LiteralPath $dir) {
      # Scope excludes test fixtures, which deliberately hold violation samples.
      # ref: allow-and-deny-lists.instructions.md#B6 -- structural invariants; vendored and secret files are separate concerns
      $lcpFiles += Get-ChildItem -Path $dir -Recurse -Include '*.nix', '*.sh', '*.ps1', '*.psm1', '*.yml' |
        Where-Object { $_.FullName -notmatch '(^|[\\\/])(vendor|secrets|tests[\\\/]fixtures)([\\\/]|$)' } |
        Select-GitIgnored
    }
  }

  $lcpDiscardPattern = '(StandardOutPath|StandardErrorPath|StandardOutput|StandardError)\s*=\s*"/dev/null"'
  foreach ($f in $lcpFiles) {
    # Exclude this check's own twins: their source contains the literal pattern text.
    if ((Split-Path -Leaf $f) -in ($allStepLeaves + $allStepShLeaves)) { continue }  # WHY: $f is a string from Select-GitIgnored, not a FileInfo object
    $lcpRel = $f.Substring($r.Length + 1) -replace '\\', '/'

    # Rule 1: no capture directive may discard a stream.
    Select-String -Path $f -Pattern $lcpDiscardPattern | ForEach-Object {
      Write-ErrorMessage "log capture pair: '$lcpRel`:$($_.LineNumber)' discards a stream to /dev/null; capture stdout.log and stderr.log instead (output-handling.instructions.md)"
      $lcpErrors++
    }

    # Rule 2: no merged-stream redirection.
    Select-String -Path $f -Pattern '*>>' -SimpleMatch | ForEach-Object {
      Write-ErrorMessage "log capture pair: '$lcpRel`:$($_.LineNumber)' merges stdout and stderr; use 1>> and 2>> into stdout.log and stderr.log"
      $lcpErrors++
    }

    # Rule 3: capture is both-or-neither per file, per directive family.
    # WHY boolean presence: a file may own several services, so only the lone-stream case
    # is a violation -- with one stream captured and the other discarded, the discarded
    # stream lands in whatever the platform default is.
    $lcpRaw = Get-Content -LiteralPath $f -Raw
    if (($lcpRaw -match 'StandardOutPath') -ne ($lcpRaw -match 'StandardErrorPath')) {
      Write-ErrorMessage "log capture pair: '$lcpRel' declares only one of StandardOutPath/StandardErrorPath; declare both or neither"
      $lcpErrors++
    }
    if (($lcpRaw -match 'StandardOutput\s*=') -ne ($lcpRaw -match 'StandardError\s*=')) {
      Write-ErrorMessage "log capture pair: '$lcpRel' declares only one of StandardOutput/StandardError; declare both or neither"
      $lcpErrors++
    }
  }

  if ($lcpErrors -gt 0) {
    Write-ErrorMessage "log capture pair policy check failed with $lcpErrors error(s)"
    $failed = $true
  } else {
    Write-Message "log capture pair policy passed."
  }

  if ($failed) {
    Write-ErrorMessage "repository policy (pattern-based) check failed"
    return $false
  }

  Write-Message "repository policy (pattern-based) passed."
  return $true
}
