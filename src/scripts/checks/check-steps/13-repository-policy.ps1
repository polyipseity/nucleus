Register-Step -Id "repository-policy" -Number 13 -Name "Repository policy" -Action {
  param($HasArgs, $RepoRoot, $PositionalArgs)

  $r = if ($RepoRoot) { $RepoRoot } else { Split-Path -Parent (Split-Path -Parent $PSScriptRoot) }
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

    # Skip agent customization files (consumed as a directory via Method 4)  # ref: allow-and-deny-lists.instructions.md#A2 -- agents/* consumed as directory
    $relPath = $_.FullName.Substring($using:cfgDir.Length + 1) -replace '\\', '/'
    if ($relPath -like 'agents/*') { return $null }

    # Check against cached Select-String output -- relative path first, then basename
    $refs = @($using:cfgSelectOutput | Where-Object { $_.Line -match [regex]::Escape($relPath) })
    if ($refs.Count -eq 0) {
      $refs = @($using:cfgSelectOutput | Where-Object { $_.Line -match [regex]::Escape($basename) })
    }
    if ($refs.Count -eq 0) {
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
      # Check preceding line using cached check-suppress:config-method output
      if ($ref.LineNumber -gt 1) {
        $prevLineNum = $ref.LineNumber - 1
        $prevMatch = $using:cfgMethodOutput | Where-Object { $_.Path -eq $ref.Path -and $_.LineNumber -eq $prevLineNum }
        if ($prevMatch) {
          $hasMethod = $true
          break
        }
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

  Write-Message "--- activation token placeholder ---"

  $actPattern = '^\s*#.*__[A-Z][A-Z_]*__'
  $actViolations = @()

  if ($HasArgs) {
    $actFiles = $PositionalArgs | Where-Object { $_ -like '*.sh' -or $_ -like '*.zsh' }
    if ($actFiles.Count -gt 0) {
      $actViolations += Select-String -Path $actFiles -Pattern $actPattern | ForEach-Object { "$($_.Path):$($_.LineNumber)" }
    }
  } else {
    $actFiles = Get-ChildItem -Recurse -Path (Join-Path $r "src\scripts") -Include '*.sh', '*.zsh' | ForEach-Object { $_.FullName }
    $actViolations += Select-String -Path $actFiles -Pattern $actPattern | ForEach-Object { "$($_.Path):$($_.LineNumber)" }
  }

  if ($actViolations.Count -gt 0) {
    foreach ($av in ($actViolations | Sort-Object -Unique)) { Write-ErrorMessage $av }
    Write-ErrorMessage "token placeholder strings found in script comments"
    $failed = $true
  } else {
    Write-Message "no token placeholder strings in script comments."
  }

  Write-Message "--- preflight install command policy ---"

  $preflightViolations = @()

  # Find all .ps1 files
  # WHY: if-expression output is pipeline-enumerated — an empty branch yields $null, crashing the .Count check below under StrictMode; the @() wrapper forces an array
  $ps1Files = @(if ($HasArgs) {
    if ($script:PS1_FILES) { $script:PS1_FILES } else { @($PositionalArgs | Where-Object { $_ -like '*.ps1' }) }
  } else {
    @(Get-ChildItem -Recurse -Path $r -Include '*.ps1' | Where-Object { $_.FullName -notmatch '[\\/]vendor[\\/]' } | ForEach-Object { $_.FullName } | Select-GitIgnored)  # ref: allow-and-deny-lists.instructions.md#B6 -- structural invariant; gitignore filter applied on top
  })

  if ($ps1Files.Count -gt 0) {
    # Exclude this check's own file: its source contains the literal pattern text.
    # ref: allow-and-deny-lists.instructions.md#B6 -- structural invariant; self-refs are dynamic
    $selfLeaf = Split-Path -Leaf $PSCommandPath
    $selMatches = Select-String -Path $ps1Files -Pattern 'Assert-ToolAvailable.*-InstallCommand' -AllMatches |
      Where-Object { (Split-Path -Leaf $_.Path) -ne $selfLeaf }
    foreach ($m in $selMatches) {
      $preflightViolations += "$($m.Path):$($m.LineNumber) ($($m.Line.Trim()))"
    }
  }

  if ($preflightViolations.Count -gt 0) {
    foreach ($v in $preflightViolations) {
      Write-Error "check: error: $v"
    }
    Write-Output "check:   Remove -InstallCommand parameters from Assert-ToolAvailable calls — preflight checks must hard-fail, not suggest install."
    $failed = $true
  } else {
    Write-Output "check: no preflight InstallCommand violations found."
  }

  Write-Message "--- embedded content enforcement ---"

  $embeddedViolations = @()
  $embeddedSelfLeaf = Split-Path -Leaf $PSCommandPath

  # WHY: if-expression output is pipeline-enumerated — an empty branch yields $null, crashing the .Count checks below under StrictMode; the @() wrapper forces an array
  $embeddedPs1Files = @(if ($HasArgs) {
    if ($script:PS1_FILES) { $script:PS1_FILES } else { @($PositionalArgs | Where-Object { $_ -like '*.ps1' }) }
  } else {
    @(Get-ChildItem -Recurse -Path $r -Include '*.ps1' | Where-Object { $_.FullName -notmatch '[\\/]vendor[\\/]' } | ForEach-Object { $_.FullName } | Select-GitIgnored)  # ref: allow-and-deny-lists.instructions.md#C5 -- structural invariant; gitignore filter applied on top
  })

  $writeCommands = @('Set-Content', 'Add-Content', 'Out-File', 'Tee-Object')

  foreach ($file in $embeddedPs1Files) {
    # Exclude this check's own file: its source contains the literal here-string patterns.
    # ref: allow-and-deny-lists.instructions.md#C5 -- self-refs are dynamic
    if ((Split-Path -Leaf $file) -eq $embeddedSelfLeaf) { continue }

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
      Write-Error "check: error: $v"
    }
    Write-Output "check:   Extract here-strings above 10 content lines to shared files — see .agents/instructions/embedded-content.instructions.md."
    $failed = $true
  } else {
    Write-Output "check: no embedded-content violations found."
  }

  Write-Message "--- agents policy ---"

  $repoCommitStaged = Join-Path $r '.agents\prompts\commit-staged.prompt.md'
  $userCommitStaged = Join-Path $r 'src\users\default\agents\prompts\commit-staged.prompt.md'
  function Get-PromptBodyWithoutFrontmatter {
    param([string]$Path)
    $lines = Get-Content -LiteralPath $Path
    $inFrontmatter = $false
    $frontmatterCount = 0
    $body = [System.Collections.Generic.List[string]]::new()
    foreach ($line in $lines) {
      if ($line -eq '---') {
        $frontmatterCount++
        if ($frontmatterCount -eq 1) { $inFrontmatter = $true; continue }
        if ($frontmatterCount -eq 2) { $inFrontmatter = $false; continue }
      }
      if (-not $inFrontmatter -and $frontmatterCount -ge 2) {
        $body.Add($line) | Out-Null
      }
    }
    return ($body -join "`n")
  }
  $repoBody = Get-PromptBodyWithoutFrontmatter -Path $repoCommitStaged
  $userBody = Get-PromptBodyWithoutFrontmatter -Path $userCommitStaged
  if ($repoBody -ne $userBody) {
    Write-ErrorMessage 'commit-staged.prompt.md body mismatch between repo and user overlay'
    $failed = $true
  } else {
    Write-Output 'check: commit-staged prompt bodies match.'
  }

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
    Write-Output 'check: AGENTS.md instruction links resolve.'
  }

  Write-Message '--- no real-user test coupling ---'

  $usersRoot = Join-Path -Path $r -ChildPath 'src\users'
  foreach ($userDir in Get-ChildItem -Path $usersRoot -Directory) {
    if ($userDir.Name -eq 'default') { continue }
    $userName = $userDir.Name
    $hits = Select-String -Path (Join-Path $r 'tests') -Pattern "\b$([regex]::Escape($userName))\b" -Recurse -ErrorAction SilentlyContinue
    foreach ($hit in $hits) {
      Write-ErrorMessage "tests must not reference production user '$userName': $($hit.Path):$($hit.LineNumber):$($hit.Line.Trim()) (see testing.instructions.md: No real-user test coupling)"
      $failed = $true
    }
  }
  if (-not $failed) {
    Write-Output 'check: no real-user test coupling policy passed.'
  }

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
      $dummySelfLeaf = Split-Path -Leaf $PSCommandPath
      $dummySelfShLeaf = Split-Path -Leaf ([System.IO.Path]::ChangeExtension($PSCommandPath, '.sh'))

      # WHY: if-expression output is pipeline-enumerated — an empty branch yields $null, crashing the .Count check below under StrictMode; the @() wrapper forces an array
      $dummyFiles = @(if ($HasArgs) {
        @($PositionalArgs | Where-Object {
            $_ -notmatch '(^|[\\/])(src[\\/]secrets[\\/]|vendor[\\/]|tests[\\/]fixtures[\\/])' -and
            $_ -notmatch '\.schema\.json$' -and
            (Split-Path -Leaf $_) -notin @($dummySelfLeaf, $dummySelfShLeaf)
          })
      } else {
        @(git ls-files | Select-GitIgnored | Where-Object {
            $_ -notmatch '(^|[\\/])(src[\\/]secrets[\\/]|vendor[\\/]|tests[\\/]fixtures[\\/])' -and
            $_ -notmatch '\.schema\.json$' -and
            (Split-Path -Leaf $_) -notin @($dummySelfLeaf, $dummySelfShLeaf)
          })  # ref: allow-and-deny-lists.instructions.md#B6 -- structural invariant; gitignore filter applied on top
      })

      if ($dummyFiles.Count -gt 0) {
        $dummyMatches = Select-String -Path $dummyFiles -Pattern '\bsk-[A-Za-z0-9-]{4,}' -AllMatches -CaseSensitive
        foreach ($m in $dummyMatches) {
          foreach ($lit in @($m.Matches | ForEach-Object { $_.Value } | Select-Object -Unique)) {
            if ($registeredDummyValues -cnotcontains $lit) {
              Write-ErrorMessage "unregistered dummy API key literal '$lit' at $($m.Path):$($m.LineNumber) (register it in src/modules/dummy-keys.json or use a registered value)"
              $dummyErrors++
            }
          }
        }
      }

      if ($dummyErrors -gt 0) {
        Write-Output 'check:   Register new dummy keys in src/modules/dummy-keys.json and use registered values in consumers.'
        $failed = $true
      } else {
        Write-Message "dummy key uniformity policy passed."
      }
    } else {
      Write-ErrorMessage "dummy-key registry $dummyRegistry is missing the dummyKeys object"
      $failed = $true
    }
  }

  if ($failed) {
    Write-ErrorMessage "repository policy check failed"
    return $false
  }

  Write-Message "repository policy passed."
  return $true
}
