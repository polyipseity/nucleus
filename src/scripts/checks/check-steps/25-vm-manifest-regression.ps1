Register-Step -Id "vm-manifest-regression" -Number 25 -Name "VM manifest regression gate" -Action {
  param($HasArgs, $RepoRoot, $PositionalArgs)

  $r = if ($RepoRoot) { $RepoRoot } else { Split-Path -Parent (Split-Path -Parent $PSScriptRoot) }

  $violations = @()
  $selfLeaves = @('25-vm-manifest-regression.sh', '25-vm-manifest-regression.ps1')

  # Scope: production code under src/ and scripts/ with code extensions —
  # same scope as the legacy-token gate (step 23). .md prose, tests/ fixtures,
  # and the manifest/schema (VMs.json, VMs.schema.json) are excluded by scope.
  $extensions = @('.ps1', '.sh', '.zsh', '.nix', '.yml')

  $scanFiles = if ($HasArgs) {
    @($PositionalArgs | Where-Object {
      (($_ -like 'src/*') -or ($_ -like 'scripts/*')) -and
      ($extensions -contains [System.IO.Path]::GetExtension($_)) -and
      ($selfLeaves -notcontains (Split-Path -Leaf $_))
    })
  } else {
    @(Get-ChildItem -Path (Join-Path $r 'src'), (Join-Path $r 'scripts') -Recurse -File |
      Where-Object { $extensions -contains $_.Extension } |
      Where-Object { $selfLeaves -notcontains $_.Name } |
      ForEach-Object { ([System.IO.Path]::GetRelativePath($r, $_.FullName)).Replace('\', '/') } |
      Select-GitIgnored)
  }

  # G2 scope — VM backend code under src/scripts + src/hosts + scripts/vm.*,
  # minus the two size parsers whose factor tables legitimately define GiB.
  $g2Files = @($scanFiles | Where-Object {
    (($_ -like 'src/scripts/*') -or ($_ -like 'src/hosts/*') -or ($_ -in @('scripts/vm.sh', 'scripts/vm.ps1'))) -and
    ($_ -notlike 'src/scripts/lib/size.sh') -and
    ($_ -notlike 'src/hosts/Windows/modules/SizeStrings.ps1')
  })

  # G3/G6 scope — all files minus the three size parsers (they define the grammar).
  $g3Files = @($scanFiles | Where-Object {
    ($_ -notlike 'src/scripts/lib/size.sh') -and
    ($_ -notlike 'src/hosts/Windows/modules/SizeStrings.ps1') -and
    ($_ -notlike 'src/modules/lib/size.nix')
  })

  $guards = @(
    # G1: no byte-count manifest property refs (ramBytes/diskBytes) — production
    # consumers must use the parsed .ram/.diskSize values.
    @{ Label = 'byte-count manifest property reference (ramBytes/diskBytes)'; Pattern = '\.ramBytes|\.diskBytes|"ramBytes"|"diskBytes"'; Allow = '^$'; Files = $scanFiles },
    # G2: no binary GiB literals (524288/536870912/1073741824) outside the size
    # parser factor tables and the documented tart/Packer whole-GiB adapter
    # (vm.sh `_mem_gib` line — see its WHY comment).
    @{ Label = 'binary GiB literal (524288/536870912/1073741824)'; Pattern = '524288|536870912|1073741824'; Allow = '_mem_gib='; Files = $g2Files },
    # G3: no 1048576 (1 MiB) outside the three size parser files.
    @{ Label = 'binary MiB literal (1048576)'; Pattern = '1048576'; Allow = '^$'; Files = $g3Files },
    # G4: no `.display` manifest property refs (`.displayName` is a different,
    # unrelated field). `power.sleep.display` (macOS power management) is allowed.
    @{ Label = '.display manifest property reference'; Pattern = '\.display([^A-Za-z0-9_]|$)|vm\.display([^A-Za-z0-9_]|$)|"display"'; Allow = 'power\.sleep\.display'; Files = $scanFiles },
    # G5: no hard-coded host-side ports — guest port forwards must come from the
    # manifest portForwards (2222/5555/5554 host refs belong only in manifest/tests/docs).
    @{ Label = 'hard-coded host-side port (2222/5555/5554)'; Pattern = 'hostfwd=tcp::(2222|5555|5554)|localhost:(2222|5555|5554)|-p (2222|5555|5554)|::(2222|5555|5554)-:|<integer>(2222|5555|5554)</integer>'; Allow = '^$'; Files = $scanFiles },
    # G6: no invalid suffix forms KB/KiB — except the parser doc comments (excluded
    # by scope above) and the pre-existing health-check message (df -Pk reports 1K
    # blocks, i.e. KiB).
    @{ Label = 'invalid suffix KB/KiB'; Pattern = '(^|[^A-Za-z])KB([^A-Za-z]|$)|(^|[^A-Za-z])KiB([^A-Za-z]|$)'; Allow = 'KiB available'; Files = $g3Files },
    # G7: no unit-in-identifier names (mib/gib) — except the sanctioned tart/Packer
    # adapter vars (_disk_gib/_mem_gib/disk_size_gib/memory_gib) and the scripts/vm.sh
    # decimal display rounding (ram_gib, pinned by vm-setup-tests.nix).
    @{ Label = 'unit-in-identifier (mib/gib)'; Pattern = 'mib|gib'; Allow = '_disk_gib|_mem_gib|ram_gib|disk_size_gib|memory_gib'; Files = $scanFiles }
  )

  foreach ($g in $guards) {
    foreach ($file in $g.Files) {
      $content = Get-Content -Raw -Path $file
      $lineNo = 0
      foreach ($line in ($content -split "`r?`n")) {
        $lineNo++
        if ($line -match $g.Pattern -and -not ($line -match $g.Allow)) {
          $violations += "${file}:${lineNo}: $($g.Label)"
        }
      }
    }
  }

  if ($violations.Count -gt 0) {
    foreach ($v in $violations) {
      Write-Error "check: error: $v"
    }
    Write-Output "check:   VM size/port references must follow the manifest contract — see .agents/instructions/vm-management.instructions.md (suffix grammar) and src/modules/VMs.schema.json (portForwards)."
    throw "VM manifest regression check failed: $($violations.Count) violation(s) found."
  }

  Write-Output "check: no VM manifest contract regressions found."
}
