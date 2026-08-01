Register-Step -Id "embedded-content-enforcement" -Number 22 -Name "Embedded content enforcement" -Action {
  param($HasArgs, $RepoRoot, $PositionalArgs)

  $r = if ($RepoRoot) { $RepoRoot } else { Split-Path -Parent (Split-Path -Parent $PSScriptRoot) }

  $violations = @()
  $selfLeaf = Split-Path -Leaf $PSCommandPath

  $ps1Files = if ($HasArgs) {
    if ($script:PS1_FILES) { $script:PS1_FILES } else { @($PositionalArgs | Where-Object { $_ -like '*.ps1' }) }
  } else {
    @(Get-ChildItem -Recurse -Path $r -Include '*.ps1' | Where-Object { $_.FullName -notmatch '[\\/]vendor[\\/]' } | ForEach-Object { $_.FullName } | Select-GitIgnored)  # ref: allow-and-deny-lists.instructions.md#C5 -- structural invariant; gitignore filter applied on top
  }

  $writeCommands = @('Set-Content', 'Add-Content', 'Out-File', 'Tee-Object')

  foreach ($file in $ps1Files) {
    # Exclude this check's own file: its source contains the literal here-string patterns.
    # ref: allow-and-deny-lists.instructions.md#C5 -- self-refs are dynamic
    if ((Split-Path -Leaf $file) -eq $selfLeaf) { continue }

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

      $violations += "${file}:$($hs.Extent.StartLineNumber): here-string with $contentLines content lines (limit 10) — extract to a shared file per the embedded-content policy"
    }
  }

  if ($violations.Count -gt 0) {
    foreach ($v in $violations) {
      Write-Error "check: error: $v"
    }
    Write-Output "check:   Extract here-strings above 10 content lines to shared files — see .agents/instructions/embedded-content.instructions.md."
    throw "Embedded content enforcement check failed: $($violations.Count) violation(s) found."
  }

  Write-Output "check: no embedded-content violations found."
}
