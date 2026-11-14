<#
.SYNOPSIS
    Verifies that the Windows VM sync updates guest scripts in place, mirroring
    vm_write_if_changed and the write-then-prune order in
    src/scripts/lib/vm.sh.
.DESCRIPTION
    Static analysis tests (parse the source, do not execute).  Enforces the
    parity invariant for generated guest scripts:

    - One top-level Write-VMScriptIfChanged helper compares the existing bytes
      and writes only when they differ, so an unchanged script keeps its inode.
    - Every start, stop, and pack/unpack renderer goes through that helper and
      none of them uses Set-Content.
    - The prune runs after the writers, removes only managed names that the
      manifest no longer asks for, and reports the removals under -DryRun.
    - No pre-write prune survives, which is the behavior this parity change
      removes: deleting every generated script before rewriting recycles them on
      Windows, where Remove-Item is the managed safe delete.
    - An Android guest renders only its .ps1 start script.

.NOTES
    Run with: pwsh -NoProfile -Command "Invoke-Pester tests/platforms/Windows/modules/system/vm-script-sync.Tests.ps1 -Output Detailed"
    Exit codes: 0 on success; 1 on failure
#>

BeforeAll {
  $ErrorActionPreference = "Stop"

  $RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..\..\..\..\")
  $InvokeVMSetupPath = Join-Path $RepoRoot "src\platforms\Windows\modules\system\Invoke-VMSetup.ps1"

  # Read through a closure so PSUseDeclaredVarsMoreThanAssignments sees the path
  # used inside the It blocks, which are sibling scopes.
  function Get-VMSetupContent { return Get-Content -Raw -Path $InvokeVMSetupPath }

  # Slice of the source between two literal markers, starting the search for the
  # end marker at -From when given. Markers keep every assertion anchored to the
  # structure the reviewer named, and a missing marker fails the case loudly
  # instead of matching nothing.
  function Get-SourceSlice {
    param(
      [Parameter(Mandatory)][string]$Content,
      [Parameter(Mandatory)][string]$StartMarker,
      [Parameter(Mandatory)][string]$EndMarker,
      [int]$From = 0
    )
    $start = $Content.IndexOf($StartMarker, $From, [System.StringComparison]::Ordinal)
    if ($start -lt 0) { throw "start marker not found: $StartMarker" }
    $end = $Content.IndexOf($EndMarker, $start, [System.StringComparison]::Ordinal)
    if ($end -lt 0) { throw "end marker not found after '$StartMarker': $EndMarker" }
    return $Content.Substring($start, $end - $start)
  }
}

Describe "Windows VM guest-script sync" {
  It "defines Write-VMScriptIfChanged before Invoke-VMSetup" {
    $content = Get-VMSetupContent
    $helperIndex = $content.IndexOf('function Write-VMScriptIfChanged', [System.StringComparison]::Ordinal)
    $setupIndex = $content.IndexOf('function Invoke-VMSetup', [System.StringComparison]::Ordinal)
    $helperIndex | Should -BeGreaterThan -1 -Because "the shared writer must exist as a top-level function"
    $setupIndex | Should -BeGreaterThan -1
    $helperIndex | Should -BeLessThan $setupIndex -Because "a nested helper cannot be reused by the writers"
  }

  It "compares the existing bytes and writes only when they differ" {
    $content = Get-VMSetupContent
    $helper = Get-SourceSlice -Content $content -StartMarker 'function Write-VMScriptIfChanged' -EndMarker 'function Invoke-VMSetup'

    $helper | Should -Match ([regex]::Escape('Get-Content -LiteralPath $Path -Raw'))
    $helper | Should -Match ([regex]::Escape('[System.IO.File]::WriteAllText($Path, $Content, [System.Text.UTF8Encoding]::new($false))'))
    $helper | Should -Match ([regex]::Escape('[System.StringComparison]::Ordinal'))
    $helper | Should -Match ([regex]::Escape("if (`$null -eq `$existing) { `$existing = '' }"))
    $helper | Should -Not -Match ([regex]::Escape('Set-Content'))
    $helper | Should -Not -Match ([regex]::Escape('Remove-Item'))

    $falseIndex = $helper.IndexOf('return $false', [System.StringComparison]::Ordinal)
    $writeIndex = $helper.IndexOf('WriteAllText', [System.StringComparison]::Ordinal)
    $falseIndex | Should -BeGreaterThan -1 -Because "a matching file must short-circuit"
    $falseIndex | Should -BeLessThan $writeIndex -Because "the short-circuit has to precede the write"
  }

  It "writes every start, stop, and pack/unpack script through the shared helper" {
    $content = Get-VMSetupContent
    $writers = Get-SourceSlice -Content $content `
      -StartMarker 'function Invoke-VMWriteStartHelper' `
      -EndMarker '$manifest = Join-Path $RepoRoot'

    $writers | Should -Not -Match ([regex]::Escape('Set-Content'))
    $writers | Should -Not -Match ([regex]::Escape('Remove-Item'))
    $callCount = [regex]::Matches($writers, 'Write-VMScriptIfChanged').Count
    $callCount | Should -BeGreaterOrEqual 8 -Because "Android start, start .ps1, start .sh, stop .ps1, and four pack/unpack wrappers each go through it"
  }

  It "reports updated versus up to date instead of claiming a write" {
    $content = Get-VMSetupContent
    $writers = Get-SourceSlice -Content $content `
      -StartMarker 'function Invoke-VMWriteStartHelper' `
      -EndMarker '$manifest = Join-Path $RepoRoot'

    $writers | Should -Match ([regex]::Escape(' updated: '))
    $writers | Should -Match ([regex]::Escape(' up to date: '))
    $writers | Should -Match ([regex]::Escape('Write-NucleusNotice'))
  }

  It "renders only the .ps1 start script for an Android guest" {
    $content = Get-VMSetupContent
    $android = Get-SourceSlice -Content $content `
      -StartMarker 'if ($Vm.type -eq ''Android'') {' `
      -EndMarker '$hostArch = $env:PROCESSOR_ARCHITECTURE'

    $android | Should -Match ([regex]::Escape('Join-Path $ScriptsDir "start-$($Vm.id).ps1"'))
    $android | Should -Not -Match ([regex]::Escape('start-$($Vm.id).sh'))
  }

  It "builds the desired name set and prunes only names outside it, after the writers run" {
    $content = Get-VMSetupContent
    $packCallIndex = $content.IndexOf('Invoke-VMWritePackUnpackHelper -ScriptsDir $scriptsDir', [System.StringComparison]::Ordinal)
    $desiredIndex = $content.IndexOf('$desiredScriptNames', [System.StringComparison]::Ordinal)
    $packCallIndex | Should -BeGreaterThan -1
    $desiredIndex | Should -BeGreaterThan $packCallIndex -Because "the prune must follow the writers, not precede them"

    $writersLoop = $content.IndexOf('foreach ($vm in $vmDef.VMs) {', [System.StringComparison]::Ordinal)
    $writersLoop | Should -BeGreaterThan -1
    $prune = Get-SourceSlice -Content $content `
      -StartMarker '$desiredScriptNames' `
      -EndMarker 'foreach ($vm in $vmDef.VMs) {' `
      -From ($writersLoop + 1)

    $prune | Should -Match ([regex]::Escape('$desiredScriptNames.Add("start-$($desiredVm.id).ps1")'))
    $prune | Should -Match ([regex]::Escape('$desiredScriptNames.Add("start-$($desiredVm.id).sh")'))
    $prune | Should -Match ([regex]::Escape('$desiredScriptNames.Add("stop-$($desiredVm.id).ps1")'))
    $prune | Should -Match ([regex]::Escape("-not `$desiredScriptNames.Contains(`$_.Name)"))
    $prune | Should -Match ([regex]::Escape("-match '^(start-|stop-|pack\.|unpack\.)'"))
    $prune | Should -Match ([regex]::Escape('Remove-Item -LiteralPath $stale.FullName -Force'))
    $prune | Should -Match ([regex]::Escape('Write-NucleusDryRun -CommandName vm-sync'))
    $prune | Should -Match ([regex]::Escape('if ($DryRun)'))
  }

  It "keeps a non-Android guest's .sh in the desired set only" {
    $content = Get-VMSetupContent
    $packCallIndex = $content.IndexOf('Invoke-VMWritePackUnpackHelper -ScriptsDir $scriptsDir', [System.StringComparison]::Ordinal)
    $prune = $content.Substring($packCallIndex)
    $prune | Should -Match ([regex]::Escape("if (`$desiredVm.type -ne 'Android')"))
  }

  It "no longer deletes every generated script before rewriting" {
    $content = Get-VMSetupContent
    $preWrite = Get-SourceSlice -Content $content `
      -StartMarker '$scriptsDir = Join-Path $vmDir ''scripts''' `
      -EndMarker 'foreach ($vm in $vmDef.VMs) {'

    $preWrite | Should -Not -Match ([regex]::Escape('Remove-Item'))
    $preWrite | Should -Not -Match ([regex]::Escape('Get-ChildItem'))
    $content | Should -Not -Match ([regex]::Escape("-match '^(start|stop)-.+\.(sh|ps1)$'"))
  }
}
