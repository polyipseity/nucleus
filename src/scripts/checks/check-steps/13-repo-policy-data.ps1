Register-Step -Id "repo-policy-data" -Name "Repository policy (data-driven)" -Action {
  param([Parameter(Mandatory)][PSObject]$Context)

  $HasArgs = $Context.HasArgs
  $RepoRoot = $Context.RepoRoot
  $PositionalArgs = $Context.PositionalArgs

  $r = if ($RepoRoot) { $RepoRoot } else { Split-Path -Parent (Split-Path -Parent $PSScriptRoot) }
  $selfLeaf = if ($PSCommandPath) { Split-Path -Leaf $PSCommandPath } else { '13-repo-policy-data.ps1' }
  # WHY: all repo-policy step files must be excluded from pattern scans to avoid self-referencing literal pattern text
  $allStepLeaves = @('11-repo-policy-grep.ps1', '12-repo-policy-pattern.ps1', '13-repo-policy-data.ps1', '14-repository-policy.ps1')
  $failed = $false

  Write-Message "--- dummy key uniformity ---"

  $dummyRegistry = Join-Path $r 'src\modules\dummy-keys.json'
  $dummyErrors = 0
  if (-not (Test-Path -LiteralPath $dummyRegistry)) {
    Write-ErrorMessage "dummy-key registry not found at $dummyRegistry"
    $failed = $true
  } else {
    $dummyRegistryData = Get-Content -LiteralPath $dummyRegistry -Raw | ConvertFrom-Json -AsHashtable
    if ($dummyRegistryData.ContainsKey('dummyKeys')) {
      $registeredDummyValues = @($dummyRegistryData['dummyKeys'].Values | ForEach-Object { $_.value })

      # Rule: every hardcoded sk- style API key literal (sk-[A-Za-z0-9]{4,}) in tracked files must be a registered dummyKeys value.
      # Exclude this check's own files: their source contains the literal pattern text.
      # ref: allow-and-deny-lists.instructions.md#C5 -- self-refs are dynamic
      $dummySelfLeaf = $selfLeaf
      $dummySelfShLeaf = $selfShLeaf

      # WHY: if-expression output is pipeline-enumerated — an empty branch yields $null, crashing the .Count check below under StrictMode; the @() wrapper forces an array
      $dummyFiles = @(if ($HasArgs) {
        @($PositionalArgs | Where-Object {
            $_ -notmatch '(^|[\\/])(src[\\/]secrets[\\/]|vendor[\\/]|tests[\\/]fixtures[\\/])' -and
            $_ -notmatch '\.schema\.json$' -and
            (Split-Path -Leaf $_) -notin @($dummySelfLeaf, $dummySelfShLeaf) + $allStepLeaves
          })
      } else {
        @(git ls-files | Select-GitIgnored | Where-Object {
            $_ -notmatch '(^|[\\/])(src[\\/]secrets[\\/]|vendor[\\/]|tests[\\/]fixtures[\\/])' -and
            $_ -notmatch '\.schema\.json$' -and
            (Split-Path -Leaf $_) -notin @($dummySelfLeaf, $dummySelfShLeaf) + $allStepLeaves
          })  # ref: allow-and-deny-lists.instructions.md#B6 -- structural invariant; gitignore filter applied on top
      })

      if ($dummyFiles.Count -gt 0) {
        # WHY: in args mode $PositionalArgs may carry non-file tokens (e.g. a step id like "repository-policy"); Select-String -Path throws on a missing path under Stop, whereas the .sh twin's grep silently skips them. Filter to existing files to match twin behavior.
        $dummyExisting = @($dummyFiles | Where-Object { Test-Path -LiteralPath $_ })
        if ($dummyExisting.Count -gt 0) {
          $dummyMatches = Select-String -Path $dummyExisting -Pattern '\bsk-[A-Za-z0-9-]{4,}' -AllMatches -CaseSensitive
          foreach ($m in $dummyMatches) {
            foreach ($lit in @($m.Matches | ForEach-Object { $_.Value } | Select-Object -Unique)) {
              if ($registeredDummyValues -cnotcontains $lit) {
                Write-ErrorMessage "unregistered dummy API key literal '$lit' at $($m.Path):$($m.LineNumber) (register it in src/modules/dummy-keys.json or use a registered value)"
                $dummyErrors++
              }
            }
          }
        }
      }

      if ($dummyErrors -gt 0) {
        Write-Message '  Register new dummy keys in src/modules/dummy-keys.json and use registered values in consumers.'
        $failed = $true
      } else {
        Write-Message "dummy key uniformity policy passed."
      }
    } else {
      Write-ErrorMessage "dummy-key registry $dummyRegistry is missing the dummyKeys object"
      $failed = $true
    }
  }

  Write-Message "--- preflight install command policy ---"

  $preflightViolations = @()

  # Find all .ps1 files
  # WHY: if-expression output is pipeline-enumerated — an empty branch yields $null, crashing the .Count check below under StrictMode; the @() wrapper forces an array
  $ps1Files = @(if ($HasArgs) {
    if ($Context.Ps1Files) { $Context.Ps1Files } else { @($PositionalArgs | Where-Object { $_ -like '*.ps1' }) }
  } else {
    @(Get-ChildItem -Recurse -Path $r -Include '*.ps1' | Where-Object { $_.FullName -notmatch '[\\/]vendor[\\/]' } | ForEach-Object { $_.FullName } | Select-GitIgnored)  # ref: allow-and-deny-lists.instructions.md#B6 -- structural invariant; gitignore filter applied on top
  })

  if ($ps1Files.Count -gt 0) {
    # Exclude this check's own file: its source contains the literal pattern text.
    # ref: allow-and-deny-lists.instructions.md#B6 -- structural invariant; self-refs are dynamic
    $selMatches = Select-String -Path $ps1Files -Pattern 'Assert-ToolAvailable.*-InstallCommand' -AllMatches |
      Where-Object { (Split-Path -Leaf $_.Path) -notin $allStepLeaves }
    foreach ($m in $selMatches) {
      $preflightViolations += "$($m.Path):$($m.LineNumber) ($($m.Line.Trim()))"
    }
  }

  if ($preflightViolations.Count -gt 0) {
    foreach ($v in $preflightViolations) {
      Write-ErrorMessage $v
    }
    Write-Message "  Remove -InstallCommand parameters from Assert-ToolAvailable calls — preflight checks must hard-fail, not suggest install."
    $failed = $true
  } else {
    Write-Message "no preflight InstallCommand violations found."
  }

  Write-Message "--- embedded content enforcement ---"

  $embeddedViolations = @()

  # WHY: if-expression output is pipeline-enumerated — an empty branch yields $null, crashing the .Count checks below under StrictMode; the @() wrapper forces an array
  $embeddedPs1Files = @(if ($HasArgs) {
    if ($Context.Ps1Files) { $Context.Ps1Files } else { @($PositionalArgs | Where-Object { $_ -like '*.ps1' }) }
  } else {
    @(Get-ChildItem -Recurse -Path $r -Include '*.ps1' | Where-Object { $_.FullName -notmatch '[\\/]vendor[\\/]' } | ForEach-Object { $_.FullName } | Select-GitIgnored)  # ref: allow-and-deny-lists.instructions.md#C5 -- structural invariant; gitignore filter applied on top
  })

  $writeCommands = @('Set-Content', 'Add-Content', 'Out-File', 'Tee-Object')

  foreach ($file in $embeddedPs1Files) {
    # Exclude this check's own file: its source contains the literal here-string patterns.
    # ref: allow-and-deny-lists.instructions.md#C5 -- self-refs are dynamic
    if ((Split-Path -Leaf $file) -in $allStepLeaves) { continue }

    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($file, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count -gt 0) { continue }  # syntax errors are reported by the lint step

    $hereStrings = $ast.FindAll({
      param($node)
      ($node -is [System.Management.Automation.Language.StringConstantExpressionAst]) -and
      ([string]$node.StringConstantType -like '*HereString')
    }, $true)

    $fileLines = @(Get-Content -Path $file)

    foreach ($hs in $hereStrings) {
      # Content lines = all lines minus the opener line and the closer line.
      $contentLines = ($hs.Extent.Text -split "`r?`n").Count - 2
      if ($contentLines -le 10) { continue }

      # C# interop (policy exception 3) is exempt up to 25 lines via Add-Type.
      $isAddType = $false
      $isDiskWrite = $false
      $node = $hs.Parent
      while ($null -ne $node) {
        if ($node -is [System.Management.Automation.Language.CommandAst]) {
          $cmdName = $node.GetCommandName()
          if ($cmdName -eq 'Add-Type') { $isAddType = $true }
          elseif ($writeCommands -contains $cmdName) { $isDiskWrite = $true }
        } elseif ($node -is [System.Management.Automation.Language.InvokeMemberExpressionAst]) {
          $member = $node.Member
          if (($member -is [System.Management.Automation.Language.StringConstantExpressionAst]) -and ($member.Value -match '^(WriteAll|AppendAll)')) { $isDiskWrite = $true }
        }
        # Pipeline form `@"..."@ | Set-Content` puts the command at the same level as the here-string.
        if ($node -is [System.Management.Automation.Language.PipelineAst]) {
          foreach ($elem in $node.PipelineElements) {
            if ($elem -is [System.Management.Automation.Language.CommandAst]) {
              $sibName = $elem.GetCommandName()
              if ($writeCommands -contains $sibName) { $isDiskWrite = $true }
            }
          }
        }
        $node = $node.Parent
      }

      if ($isAddType) {
        if ($contentLines -le 25) { continue }
      } elseif (-not $isDiskWrite) {
        continue  # not file content (e.g., script text executed in a subprocess)
      }

      # Inline policy citation (within 10 lines above) exempts the call site.
      $cited = $false
      $startIdx = [Math]::Max(0, $hs.Extent.StartLineNumber - 11)
      $endIdx = $hs.Extent.StartLineNumber - 1
      for ($i = $startIdx; $i -lt $endIdx; $i++) {
        if ($fileLines[$i] -match 'check-suppress:embedded-content') { $cited = $true; break }
      }
      if ($cited) { continue }

      $embeddedViolations += "${file}:$($hs.Extent.StartLineNumber): here-string with $contentLines content lines (limit 10) — extract to a shared file per the embedded-content policy"
    }
  }

  if ($embeddedViolations.Count -gt 0) {
    foreach ($v in $embeddedViolations) {
      Write-ErrorMessage $v
    }
    Write-Message "  Extract here-strings above 10 content lines to shared files — see .agents/instructions/embedded-content.instructions.md."
    $failed = $true
  } else {
    Write-Message "no embedded-content violations found."
  }

  Write-Message "--- agents policy ---"

  # Commit-staged body match moved to test suite (14-agents-policy-tests.sh)

  $instructionFiles = Get-ChildItem -Path (Join-Path $r '.agents\instructions') -Filter '*.instructions.md' -File
  foreach ($instr in $instructionFiles) {
    $content = Get-Content -LiteralPath $instr.FullName -Raw
    if ($content -notmatch '(?ms)\A---\s*\r?\n.*?\r?\n---') {
      Write-ErrorMessage "$($instr.FullName): missing YAML frontmatter"
      $failed = $true
      continue
    }
    if ($content -notmatch '(?m)^description:\s*"Use when') {
      Write-ErrorMessage "$($instr.FullName): description must start with \"Use when\""
      $failed = $true
    }
    if ($content -notmatch '(?m)^name:\s*') {
      Write-ErrorMessage "$($instr.FullName): missing name frontmatter field"
      $failed = $true
    }
    if ($content -notmatch '(?m)^applyTo:\s*') {
      Write-ErrorMessage "$($instr.FullName): missing applyTo frontmatter field"
      $failed = $true
    } elseif ($content -match '(?m)^applyTo:\s*"\*\*"') {
      Write-ErrorMessage "$($instr.FullName): applyTo must not be `"**`" — use scripts/**, src/**, tests/** or narrower"
      $failed = $true
    }
  }

  $agentsMd = Join-Path $r 'AGENTS.md'
  $missingLinks = Select-String -Path $agentsMd -Pattern '\.agents/instructions/[a-z0-9-]+\.instructions\.md' -AllMatches |
    ForEach-Object { $_.Matches } |
    ForEach-Object { $_.Value } |
    Sort-Object -Unique |
    Where-Object { -not (Test-Path -LiteralPath (Join-Path $r ($_ -replace '/', '\'))) }
  if ($missingLinks) {
    foreach ($link in $missingLinks) {
      Write-ErrorMessage "AGENTS.md references missing instruction file: $link"
    }
    $failed = $true
  } else {
    Write-Message 'AGENTS.md instruction links resolve.'
  }

  if ($failed) {
    Write-ErrorMessage "repository policy (data-driven) check failed"
    return $false
  }

  Write-Message "repository policy (data-driven) passed."
  return $true
}
