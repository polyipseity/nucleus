# modules/windows/shell.ps1 — Shell parity helpers for Windows.
#
# Maintains a managed block in PowerShell profile files for cross-host shell
# behavior parity (direnv hook and helper aliases).

function Sync-NucleusShellProfile {
  <#
  .SYNOPSIS
    Converges a managed shell-parity block in PowerShell profile files.

  .DESCRIPTION
    Writes or removes a bounded managed block in:
      - CurrentUserCurrentHost profile
      - CurrentUserAllHosts profile

    Managed content intentionally mirrors key POSIX shell workflow behavior:
      - direnv integration (if direnv is present)
      - common aliases (`g`, `ga`, `gc`, `gca`, `gco`, `gd`, `gl`, `gp`,
        `gpl`, `gs`, `gst`, `la`, `ll`, `v`)

    Cleanup behavior when disabled removes only the managed block.

  .PARAMETER Enabled
    Whether managed shell parity should be enforced. False removes the managed
    block from profile files.

  .EXAMPLE
    Sync-NucleusShellProfile -Enabled:$true

  .EXAMPLE
    Sync-NucleusShellProfile -Enabled:$false
  #>
  param(
    [Parameter()]
    [bool]$Enabled = $true
  )

  $managedBlockStart = '# >>> nucleus managed shell parity >>>'
  $managedBlockEnd = '# <<< nucleus managed shell parity <<<'
  $managedBlock = @(
    $managedBlockStart
    'if (Get-Command direnv -ErrorAction SilentlyContinue) {'
    '  (& direnv hook pwsh) | Out-String | Invoke-Expression'
    '}'
    'function g { & git @Args }'
    'function ga { & git add @Args }'
    'function gc { & git commit @Args }'
    'function gca { & git commit --amend @Args }'
    'function gco { & git checkout @Args }'
    'function gd { & git diff @Args }'
    'function gl { & git log --oneline --decorate --graph @Args }'
    'function gp { & git push @Args }'
    'function gpl { & git pull @Args }'
    'function gs { & git status -sb @Args }'
    'function gst { & git status @Args }'
    'function la { Get-ChildItem -Force @Args }'
    'function ll { Get-ChildItem -Force @Args }'
    'function v { & nvim @Args }'
    $managedBlockEnd
  )

  $profilePaths = @(
    $PROFILE.CurrentUserCurrentHost,
    $PROFILE.CurrentUserAllHosts
  ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique

  foreach ($profilePath in $profilePaths) {
    $profileDirectory = Split-Path -Path $profilePath -Parent
    if ($Enabled -and -not (Test-Path -Path $profileDirectory)) {
      New-Item -ItemType Directory -Path $profileDirectory -Force | Out-Null
    }

    $existingLines = @()
    if (Test-Path -Path $profilePath) {
      $existingLines = @(Get-Content -Path $profilePath)
    }

    $filteredLines = @()
    $insideManagedBlock = $false
    foreach ($line in $existingLines) {
      if ($line -eq $managedBlockStart) {
        $insideManagedBlock = $true
        continue
      }

      if ($line -eq $managedBlockEnd) {
        $insideManagedBlock = $false
        continue
      }

      if (-not $insideManagedBlock) {
        $filteredLines += $line
      }
    }

    if ($Enabled) {
      if ($filteredLines.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace($filteredLines[-1])) {
        $filteredLines += ''
      }

      $filteredLines += $managedBlock
    }

    $hasNonWhitespaceLines = ($filteredLines | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count -gt 0
    if ($hasNonWhitespaceLines) {
      [System.IO.File]::WriteAllLines($profilePath, $filteredLines, [System.Text.UTF8Encoding]::new($false))
    }
    elseif (Test-Path -Path $profilePath) {
      Remove-Item -Path $profilePath -Force -ErrorAction SilentlyContinue
    }
  }
}
