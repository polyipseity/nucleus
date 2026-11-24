# nucleus-cli-argument-tests.ps1 - tests for Resolve-NucleusArgument normalizer.
# Plain pwsh script; run directly. No Pester discovery.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Split-Path -Parent (Split-Path -Parent $scriptDir)
$libPath = Join-Path $repoRoot 'src/scripts/lib/nucleus-cli-flags.ps1'

$passed = 0
$failed = 0

function Assert-True([bool]$cond, [string]$name, [string]$detail = '') {
  if ($cond) {
    Write-Output "PASS $name"
    $script:passed++
  } else {
    if ($detail) { Write-Output "FAIL ${name}: $detail" } else { Write-Output "FAIL $name" }
    $script:failed++
  }
}

function Assert-HasSubstring([string]$haystack, [string]$needle, [string]$name) {
  $ok = $haystack.Contains($needle)
  $detail = if ($ok) { '' } else { "expected to contain '$needle', got: $haystack" }
  Assert-True -cond $ok -name $name -detail $detail
}

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("nucleus-cli-arg-test-" + [Guid]::NewGuid().ToString('n'))
New-Item -ItemType Directory -Path $tempRoot -Force > $null
$specRoots = [System.Collections.Generic.List[string]]::new()

try {
  . $libPath

  function Write-Fixture([string]$name, [string]$paramBlock, [string]$body) {
    $path = Join-Path $tempRoot $name
    $libEscaped = $libPath -replace "'", "''"
    $content = @"
param(
$paramBlock
)
Set-StrictMode -Version Latest
`$ErrorActionPreference = 'Stop'
. '$libEscaped'
`$leftover = Resolve-NucleusArgument -Arguments `$RemainingArgs -CommandPath `$PSCommandPath -CommandName 'fixture'
$body
"@
    Set-Content -Path $path -Value $content -Encoding UTF8
    return $path
  }

  function Invoke-Fixture([string]$path, [string[]]$fixtureArgs) {
    $out = & pwsh -NoProfile -File $path @fixtureArgs 2>&1 | ForEach-Object { $_.ToString() }
    $rc = $LASTEXITCODE
    return [pscustomobject]@{ Output = @($out); Rc = $rc; Text = (@($out) -join "`n") }
  }

  function New-CliSpecRepoRoot {
    [CmdletBinding(SupportsShouldProcess)]
    param([object]$spec)
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ("nucleus-cli-spec-test-" + [Guid]::NewGuid().ToString('n'))
    $specDir = Join-Path $root 'src/modules/completions'
    if ($PSCmdlet.ShouldProcess($specDir, 'Create test CLI spec repo root')) {
      New-Item -ItemType Directory -Path $specDir -Force > $null
      $specPath = Join-Path $specDir 'nucleus-cli-spec.json'
      $spec | ConvertTo-Json -Depth 20 | Set-Content -Path $specPath -Encoding UTF8
    }
    return $root
  }

  Write-Output "`n=== [1] kebab switch ==="
  $f1 = Write-Fixture -name 'f1.ps1' -paramBlock @"
  [switch]`$DryRun,
  [Parameter(ValueFromRemainingArguments)][string[]]`$RemainingArgs
"@ -body @"
Write-Output "DryRun=`$DryRun"
Write-Output "Leftover=`$(`$leftover -join ',')"
"@
  $r1 = Invoke-Fixture $f1 @('--dry-run')
  Assert-True -cond ($r1.Rc -eq 0) -name 'kebab switch exits 0' -detail $r1.Text
  Assert-HasSubstring -haystack $r1.Text -needle 'DryRun=True' -name 'kebab switch binds DryRun'

  Write-Output "`n=== [2] kebab value with space ==="
  $f2 = Write-Fixture -name 'f2.ps1' -paramBlock @"
  [string]`$LogMaxSize = '',
  [Parameter(ValueFromRemainingArguments)][string[]]`$RemainingArgs
"@ -body @"
Write-Output "LogMaxSize=`$LogMaxSize"
"@
  $r2 = Invoke-Fixture $f2 @('--log-max-size', '5')
  Assert-True -cond ($r2.Rc -eq 0) -name 'kebab value space exits 0' -detail $r2.Text
  Assert-HasSubstring -haystack $r2.Text -needle 'LogMaxSize=5' -name 'kebab value space binds'

  Write-Output "`n=== [3] kebab value with = ==="
  $f3 = Write-Fixture -name 'f3.ps1' -paramBlock @"
  [string]`$LogMaxSize = '',
  [Parameter(ValueFromRemainingArguments)][string[]]`$RemainingArgs
"@ -body @"
Write-Output "LogMaxSize=`$LogMaxSize"
"@
  $r3 = Invoke-Fixture $f3 @('--log-max-size=5')
  Assert-True -cond ($r3.Rc -eq 0) -name 'kebab value = exits 0' -detail $r3.Text
  Assert-HasSubstring -haystack $r3.Text -needle 'LogMaxSize=5' -name 'kebab value = binds'

  Write-Output "`n=== [4] acronym flags ==="
  $f4 = Write-Fixture -name 'f4.ps1' -paramBlock @"
  [switch]`$NoVMGc,
  [switch]`$GCVMData,
  [Parameter(ValueFromRemainingArguments)][string[]]`$RemainingArgs
"@ -body @"
Write-Output "NoVMGc=`$NoVMGc"
Write-Output "GCVMData=`$GCVMData"
"@
  $r4 = Invoke-Fixture $f4 @('--no-vm-gc', '--gc-vm-data')
  Assert-True -cond ($r4.Rc -eq 0) -name 'acronym flags exit 0' -detail $r4.Text
  Assert-HasSubstring -haystack $r4.Text -needle 'NoVMGc=True' -name 'no-vm-gc binds NoVMGc'
  Assert-HasSubstring -haystack $r4.Text -needle 'GCVMData=True' -name 'gc-vm-data binds GCVMData'

  Write-Output "`n=== [5] unknown flag throws and names flag ==="
  $f5 = Write-Fixture -name 'f5.ps1' -paramBlock @"
  [switch]`$DryRun,
  [Parameter(ValueFromRemainingArguments)][string[]]`$RemainingArgs
"@ -body @"
Write-Output "should-not-reach"
"@
  $r5 = Invoke-Fixture $f5 @('--bogus')
  Assert-True -cond ($r5.Rc -ne 0) -name 'unknown flag exits non-zero' -detail $r5.Text
  Assert-HasSubstring -haystack $r5.Text -needle 'bogus' -name 'unknown flag error names flag'

  Write-Output "`n=== [6] missing value throws and names flag ==="
  $f6 = Write-Fixture -name 'f6.ps1' -paramBlock @"
  [string]`$LogMaxSize = '',
  [Parameter(ValueFromRemainingArguments)][string[]]`$RemainingArgs
"@ -body @"
Write-Output "should-not-reach"
"@
  $r6 = Invoke-Fixture $f6 @('--log-max-size')
  Assert-True -cond ($r6.Rc -ne 0) -name 'missing value exits non-zero' -detail $r6.Text
  Assert-HasSubstring -haystack $r6.Text -needle 'log-max-size' -name 'missing value error names flag'

  Write-Output "`n=== [7] duplicate normalization throws ==="
  $f7 = Write-Fixture -name 'f7.ps1' -paramBlock @"
  [switch]`$FooBar,
  [Alias('foo-bar')][switch]`$Baz,
  [Parameter(ValueFromRemainingArguments)][string[]]`$RemainingArgs
"@ -body @"
Write-Output "should-not-reach"
"@
  $r7 = Invoke-Fixture $f7 @('--foo-bar')
  Assert-True -cond ($r7.Rc -ne 0) -name 'duplicate normalization exits non-zero' -detail $r7.Text
  Assert-HasSubstring -haystack $r7.Text -needle 'duplicate normalized' -name 'duplicate normalization error reports collision'

  Write-Output "`n=== [8] throws rather than exits (caller survives) ==="
  $f8 = Write-Fixture -name 'f8.ps1' -paramBlock @"
  [switch]`$DryRun,
  [Parameter(ValueFromRemainingArguments)][string[]]`$RemainingArgs
"@ -body @"
try {
  `$null = Resolve-NucleusArgument -Arguments @('--bogus') -CommandPath `$PSCommandPath -CommandName 'fixture'
  Write-Output "NO-CATCH"
} catch {
  Write-Output "CAUGHT"
}
Write-Output "AFTER"
"@
  $r8 = Invoke-Fixture $f8 @()
  Assert-True -cond ($r8.Rc -eq 0) -name 'caller survives throw' -detail $r8.Text
  Assert-HasSubstring -haystack $r8.Text -needle 'CAUGHT' -name 'caller caught throw'
  Assert-HasSubstring -haystack $r8.Text -needle 'AFTER' -name 'caller continued after catch'

  Write-Output "`n=== [9] switch =value rejects unparseable boolean ==="
  $f9 = Write-Fixture -name 'f9.ps1' -paramBlock @"
  [switch]`$DryRun,
  [Parameter(ValueFromRemainingArguments)][string[]]`$RemainingArgs
"@ -body @"
Write-Output "DryRun=`$DryRun"
"@
  $r9a = Invoke-Fixture $f9 @('--dry-run=0')
  Assert-True -cond ($r9a.Rc -ne 0) -name 'switch =0 exits non-zero' -detail $r9a.Text
  Assert-HasSubstring -haystack $r9a.Text -needle 'dry-run' -name 'switch =0 error names flag'
  Assert-HasSubstring -haystack $r9a.Text -needle '0' -name 'switch =0 error names value'
  $r9b = Invoke-Fixture $f9 @('--dry-run=no')
  Assert-True -cond ($r9b.Rc -ne 0) -name 'switch =no exits non-zero' -detail $r9b.Text
  Assert-HasSubstring -haystack $r9b.Text -needle 'no' -name 'switch =no error names value'
  $r9c = Invoke-Fixture $f9 @('--dry-run=false')
  Assert-True -cond ($r9c.Rc -eq 0) -name 'switch =false exits 0' -detail $r9c.Text
  Assert-HasSubstring -haystack $r9c.Text -needle 'DryRun=False' -name 'switch =false binds false'
  $r9d = Invoke-Fixture $f9 @('--dry-run=True')
  Assert-True -cond ($r9d.Rc -eq 0) -name 'switch =True exits 0' -detail $r9d.Text
  Assert-HasSubstring -haystack $r9d.Text -needle 'DryRun=True' -name 'switch =True binds true'

  Write-Output "`n=== [10] alias binding ==="
  $f10 = Write-Fixture -name 'f10.ps1' -paramBlock @"
  [Alias('list-logs')][switch]`$ListLogs,
  [Parameter(ValueFromRemainingArguments)][string[]]`$RemainingArgs
"@ -body @"
Write-Output "ListLogs=`$ListLogs"
Write-Output "Leftover=`$(`$leftover -join ',')"
"@
  $r10 = Invoke-Fixture $f10 @('--list-logs')
  Assert-True -cond ($r10.Rc -eq 0) -name 'alias flag exits 0' -detail $r10.Text
  Assert-HasSubstring -haystack $r10.Text -needle 'ListLogs=True' -name 'alias flag binds target param'

  Write-Output "`n=== [11] catch-all not addressable and excluded from duplicate normalization ==="
  $f11a = Write-Fixture -name 'f11a.ps1' -paramBlock @"
  [switch]`$DryRun,
  [Parameter(ValueFromRemainingArguments)][string[]]`$RemainingArgs
"@ -body @"
Write-Output "should-not-reach"
"@
  $r11a = Invoke-Fixture $f11a @('--remaining-args')
  Assert-True -cond ($r11a.Rc -ne 0) -name 'catch-all param not addressable as flag' -detail $r11a.Text
  Assert-HasSubstring -haystack $r11a.Text -needle 'remaining-args' -name 'catch-all unknown flag names flag'
  $f11b = Write-Fixture -name 'f11b.ps1' -paramBlock @"
  [Alias('remaining-args')][switch]`$Other,
  [Parameter(ValueFromRemainingArguments)][string[]]`$RemainingArgs
"@ -body @"
Write-Output "Other=`$Other"
"@
  $r11b = Invoke-Fixture $f11b @('--remaining-args')
  Assert-True -cond ($r11b.Rc -eq 0) -name 'catch-all excluded from duplicate normalization' -detail $r11b.Text
  Assert-HasSubstring -haystack $r11b.Text -needle 'Other=True' -name 'alias colliding with catch-all name binds'

  Write-Output "`n=== [12] leftover non-flag tokens mixed with flags ==="
  $f12 = Write-Fixture -name 'f12.ps1' -paramBlock @"
  [switch]`$DryRun,
  [Parameter(ValueFromRemainingArguments)][string[]]`$RemainingArgs
"@ -body @"
Write-Output "DryRun=`$DryRun"
Write-Output "Leftover=`$(`$leftover -join ',')"
"@
  $r12 = Invoke-Fixture $f12 @('--dry-run', 'foo', 'bar')
  Assert-True -cond ($r12.Rc -eq 0) -name 'mixed flags and leftovers exit 0' -detail $r12.Text
  Assert-HasSubstring -haystack $r12.Text -needle 'DryRun=True' -name 'mixed case binds flag'
  Assert-HasSubstring -haystack $r12.Text -needle 'Leftover=foo,bar' -name 'mixed case returns leftover non-flags'

  Write-Output "`n=== [13] end-of-options makes rest leftover ==="
  $f13 = Write-Fixture -name 'f13.ps1' -paramBlock @"
  [switch]`$DryRun,
  [Parameter(ValueFromRemainingArguments)][string[]]`$RemainingArgs
"@ -body @"
Write-Output "DryRun=`$DryRun"
Write-Output "Leftover=`$(`$leftover -join ',')"
"@
  # Invoke in-process: PowerShell's native param binder rejects '--' as an ambiguous
  # empty param name, so the subprocess fixture path cannot pass it through.
  $DryRun = [switch]$false
  $r13Leftover = Resolve-NucleusArgument -Arguments @('--dry-run', '--', '--not-a-flag', 'pos') -CommandPath $f13 -CommandName 'fixture'
  Assert-True -cond ($DryRun.IsPresent -eq $true) -name 'end-of-options preserves parsed flag' -detail "DryRun=$DryRun"
  Assert-True -cond (([string[]]$r13Leftover -join ',') -eq '--not-a-flag,pos') -name 'end-of-options returns remaining tokens as leftover' -detail (([string[]]$r13Leftover -join ','))

  Write-Output "`n=== [14] PassThroughUnknownFlags ==="
  $f14 = Write-Fixture -name 'f14.ps1' -paramBlock @"
  [switch]`$DryRun,
  [Parameter(ValueFromRemainingArguments)][string[]]`$RemainingArgs
"@ -body @"
Write-Output "DryRun=`$DryRun"
"@
  $DryRun = [switch]$false
  $r14a = @(Resolve-NucleusArgument -Arguments @('--bogus', '--dry-run') -CommandPath $f14 -CommandName 'fixture' -PassThroughUnknownFlags)
  Assert-True -cond ($DryRun.IsPresent -eq $true) -name 'PassThroughUnknownFlags binds known flag' -detail "DryRun=$DryRun"
  Assert-True -cond (([string[]]$r14a -join ',') -eq '--bogus') -name 'PassThroughUnknownFlags leaves unknown flag as leftover' -detail (([string[]]$r14a -join ','))

  $DryRun = [switch]$false
  $r14b = @(Resolve-NucleusArgument -Arguments @('--unknown=value', '--dry-run') -CommandPath $f14 -CommandName 'fixture' -PassThroughUnknownFlags)
  Assert-True -cond ($DryRun.IsPresent -eq $true) -name 'PassThroughUnknownFlags binds known flag with unknown=value' -detail "DryRun=$DryRun"
  Assert-True -cond (([string[]]$r14b -join ',') -eq '--unknown=value') -name 'PassThroughUnknownFlags leaves unknown=value as whole leftover token' -detail (([string[]]$r14b -join ','))

  $DryRun = [switch]$false
  $r14c = @(Resolve-NucleusArgument -Arguments @('--bogus', 'val', '--dry-run') -CommandPath $f14 -CommandName 'fixture' -PassThroughUnknownFlags)
  Assert-True -cond ($DryRun.IsPresent -eq $true) -name 'PassThroughUnknownFlags binds known flag after unknown+value' -detail "DryRun=$DryRun"
  Assert-True -cond (([string[]]$r14c -join ',') -eq '--bogus,val') -name 'PassThroughUnknownFlags preserves unknown flag followed by value order' -detail (([string[]]$r14c -join ','))

  Write-Output "`n=== [15] switch pair last-flag-wins ==="
  $f15 = Write-Fixture -name 'f15.ps1' -paramBlock @"
  [switch]`$DryRun,
  [switch]`$NoDryRun,
  [switch]`$GcOnly,
  [switch]`$NoGcOnly,
  [Parameter(ValueFromRemainingArguments)][string[]]`$RemainingArgs
"@ -body @"
Write-Output "ok"
"@
  $DryRun = [switch]$false; $NoDryRun = [switch]$false; $GcOnly = [switch]$false; $NoGcOnly = [switch]$false
  $null = Resolve-NucleusArgument -Arguments @('--dry-run', '--no-dry-run') -CommandPath $f15 -CommandName 'fixture'
  Assert-True -cond ($DryRun.IsPresent -eq $false -and $NoDryRun.IsPresent -eq $true) -name 'last flag wins: --dry-run --no-dry-run' -detail "DryRun=$DryRun NoDryRun=$NoDryRun"

  $DryRun = [switch]$false; $NoDryRun = [switch]$false; $GcOnly = [switch]$false; $NoGcOnly = [switch]$false
  $null = Resolve-NucleusArgument -Arguments @('--no-dry-run', '--dry-run') -CommandPath $f15 -CommandName 'fixture'
  Assert-True -cond ($DryRun.IsPresent -eq $true -and $NoDryRun.IsPresent -eq $false) -name 'last flag wins: --no-dry-run --dry-run' -detail "DryRun=$DryRun NoDryRun=$NoDryRun"

  $DryRun = [switch]$false; $NoDryRun = [switch]$false; $GcOnly = [switch]$false; $NoGcOnly = [switch]$false
  $null = Resolve-NucleusArgument -Arguments @('--Gc-Only', '--no-gc-only') -CommandPath $f15 -CommandName 'fixture'
  Assert-True -cond ($GcOnly.IsPresent -eq $false -and $NoGcOnly.IsPresent -eq $true) -name 'last flag wins case-insensitive: --Gc-Only --no-gc-only' -detail "GcOnly=$GcOnly NoGcOnly=$NoGcOnly"

  $DryRun = [switch]$false; $NoDryRun = [switch]$true; $GcOnly = [switch]$false; $NoGcOnly = [switch]$false
  $null = Resolve-NucleusArgument -Arguments @('--dry-run=false') -CommandPath $f15 -CommandName 'fixture'
  Assert-True -cond ($DryRun.IsPresent -eq $false -and $NoDryRun.IsPresent -eq $true) -name 'explicit =false does not clear opposite: pre-set NoDryRun stays true' -detail "DryRun=$DryRun NoDryRun=$NoDryRun"

  $DryRun = [switch]$false; $NoDryRun = [switch]$false; $GcOnly = [switch]$false; $NoGcOnly = [switch]$false
  $null = Resolve-NucleusArgument -Arguments @('--dry-run=false', '--no-dry-run') -CommandPath $f15 -CommandName 'fixture'
  Assert-True -cond ($DryRun.IsPresent -eq $false -and $NoDryRun.IsPresent -eq $true) -name 'last flag wins with =false: --dry-run=false --no-dry-run => NoDryRun true' -detail "DryRun=$DryRun NoDryRun=$NoDryRun"

  $DryRun = [switch]$false; $NoDryRun = [switch]$false; $GcOnly = [switch]$false; $NoGcOnly = [switch]$false
  $null = Resolve-NucleusArgument -Arguments @('--no-dry-run', '--dry-run=false') -CommandPath $f15 -CommandName 'fixture'
  Assert-True -cond ($DryRun.IsPresent -eq $false -and $NoDryRun.IsPresent -eq $true) -name 'last flag wins with =false: --no-dry-run --dry-run=false => NoDryRun preserved' -detail "DryRun=$DryRun NoDryRun=$NoDryRun"

  Write-Output "`n=== [16] no-platforms flag normalizes under StrictMode ==="
  $specRoot16 = New-CliSpecRepoRoot -spec ([ordered]@{
    apps = @(
      [ordered]@{
        name = 'fixture'
        globalFlags = @([ordered]@{ long = '--dry-run'; takesValue = $false })
        subcommands = @()
      }
    )
  })
  $specRoots.Add($specRoot16)
  $savedRoot = $env:NUCLEUS_REPO_ROOT
  try {
    $env:NUCLEUS_REPO_ROOT = $specRoot16
    $script:_NucleusCliSpecCacheTried = $false
    $script:_NucleusCliSpecCache = $null
    $DryRun = [switch]$false
    $null = Resolve-NucleusArgument -Arguments @('--dry-run') -CommandPath $f15 -CommandName 'fixture'
    Assert-True -cond ($DryRun.IsPresent -eq $true) -name 'no-platforms flag binds under StrictMode' -detail "DryRun=$DryRun"
  } finally {
    if ($null -eq $savedRoot) { Remove-Item Env:NUCLEUS_REPO_ROOT -ErrorAction SilentlyContinue } else { $env:NUCLEUS_REPO_ROOT = $savedRoot }
    $script:_NucleusCliSpecCacheTried = $false
    $script:_NucleusCliSpecCache = $null
  }

  Write-Output "`n=== [17] platform mismatch rejects, match passes ==="
  $specRoot17 = New-CliSpecRepoRoot -spec ([ordered]@{
    apps = @(
      [ordered]@{
        name = 'fixture'
        globalFlags = @([ordered]@{ long = '--dry-run'; takesValue = $false; platforms = @('posix') })
        subcommands = @()
      }
    )
  })
  $specRoots.Add($specRoot17)
  $savedRoot = $env:NUCLEUS_REPO_ROOT
  try {
    $env:NUCLEUS_REPO_ROOT = $specRoot17
    $script:_NucleusCliSpecCacheTried = $false
    $script:_NucleusCliSpecCache = $null
    $DryRun = [switch]$false
    if ($IsWindows) {
      $threw = $false
      $errText = ''
      try {
        $null = Resolve-NucleusArgument -Arguments @('--dry-run') -CommandPath $f15 -CommandName 'fixture'
      } catch {
        $threw = $true
        $errText = $_.Exception.Message
      }
      Assert-True -cond $threw -name 'posix-only flag rejected on windows' -detail $errText
      Assert-HasSubstring -haystack $errText -needle 'not supported on windows' -name 'posix-only rejection names platform'
    } else {
      $null = Resolve-NucleusArgument -Arguments @('--dry-run') -CommandPath $f15 -CommandName 'fixture'
      Assert-True -cond ($DryRun.IsPresent -eq $true) -name 'posix-only flag accepted on posix host' -detail "DryRun=$DryRun"
    }
  } finally {
    if ($null -eq $savedRoot) { Remove-Item Env:NUCLEUS_REPO_ROOT -ErrorAction SilentlyContinue } else { $env:NUCLEUS_REPO_ROOT = $savedRoot }
    $script:_NucleusCliSpecCacheTried = $false
    $script:_NucleusCliSpecCache = $null
  }

  Write-Output "`n=== [18] subcommand wins over global ==="
  $fExpiry = Write-Fixture -name 'fExpiry.ps1' -paramBlock @"
  [string]`$Expiry = '',
  [Parameter(ValueFromRemainingArguments)][string[]]`$RemainingArgs
"@ -body @"
Write-Output "Expiry=`$Expiry"
"@
  $specRoot18 = New-CliSpecRepoRoot -spec ([ordered]@{
    apps = @(
      [ordered]@{
        name = 'fixture'
        globalFlags = @([ordered]@{ long = '--expiry'; takesValue = $true; platforms = @('posix') })
        subcommands = @(
          [ordered]@{
            name = 'logs'
            flags = @([ordered]@{ long = '--expiry'; takesValue = $true })
          }
        )
      }
    )
  })
  $specRoots.Add($specRoot18)
  $savedRoot = $env:NUCLEUS_REPO_ROOT
  try {
    $env:NUCLEUS_REPO_ROOT = $specRoot18

    # Subcommand 'logs' wins: no platforms on subcommand flag, so accepted on any host.
    $script:_NucleusCliSpecCacheTried = $false
    $script:_NucleusCliSpecCache = $null
    $Expiry = ''
    $null = Resolve-NucleusArgument -Arguments @('--expiry', '30d') -CommandPath $fExpiry -CommandName 'fixture' -Subcommand 'logs'
    Assert-True -cond ($Expiry -eq '30d') -name 'subcommand wins over global: logs expiry binds' -detail "Expiry=$Expiry"

    # No subcommand / different subcommand: global posix-only applies.
    $script:_NucleusCliSpecCacheTried = $false
    $script:_NucleusCliSpecCache = $null
    $Expiry = ''
    if ($IsWindows) {
      $threw = $false
      $errText = ''
      try {
        $null = Resolve-NucleusArgument -Arguments @('--expiry', '30d') -CommandPath $fExpiry -CommandName 'fixture'
      } catch { $threw = $true; $errText = $_.Exception.Message }
      Assert-True -cond $threw -name 'global posix-only applies without subcommand on windows' -detail $errText
    } else {
      $null = Resolve-NucleusArgument -Arguments @('--expiry', '30d') -CommandPath $fExpiry -CommandName 'fixture'
      Assert-True -cond ($Expiry -eq '30d') -name 'global posix-only applies without subcommand on posix host' -detail "Expiry=$Expiry"
    }

    $script:_NucleusCliSpecCacheTried = $false
    $script:_NucleusCliSpecCache = $null
    $Expiry = ''
    if ($IsWindows) {
      $threw = $false
      $errText = ''
      try {
        $null = Resolve-NucleusArgument -Arguments @('--expiry', '30d') -CommandPath $fExpiry -CommandName 'fixture' -Subcommand 'other'
      } catch { $threw = $true; $errText = $_.Exception.Message }
      Assert-True -cond $threw -name 'global posix-only applies for different subcommand on windows' -detail $errText
    } else {
      $null = Resolve-NucleusArgument -Arguments @('--expiry', '30d') -CommandPath $fExpiry -CommandName 'fixture' -Subcommand 'other'
      Assert-True -cond ($Expiry -eq '30d') -name 'global posix-only applies for different subcommand on posix host' -detail "Expiry=$Expiry"
    }
  } finally {
    if ($null -eq $savedRoot) { Remove-Item Env:NUCLEUS_REPO_ROOT -ErrorAction SilentlyContinue } else { $env:NUCLEUS_REPO_ROOT = $savedRoot }
    $script:_NucleusCliSpecCacheTried = $false
    $script:_NucleusCliSpecCache = $null
  }

  Write-Output "`n=== [19] natively-bound platform-restricted param rejected via BoundParameters ==="
  $specRoot19 = New-CliSpecRepoRoot -spec ([ordered]@{
    apps = @(
      [ordered]@{
        name = 'fixture'
        globalFlags = @([ordered]@{ long = '--expiry'; takesValue = $true; platforms = @('posix') })
        subcommands = @(
          [ordered]@{
            name = 'logs'
            flags = @([ordered]@{ long = '--expiry'; takesValue = $true })
          }
        )
      }
    )
  })
  $specRoots.Add($specRoot19)
  $savedRoot = $env:NUCLEUS_REPO_ROOT
  try {
    $env:NUCLEUS_REPO_ROOT = $specRoot19

    $script:_NucleusCliSpecCacheTried = $false
    $script:_NucleusCliSpecCache = $null
    $Expiry = '30d'
    $threw19a = $false
    $err19a = ''
    try {
      $null = Resolve-NucleusArgument -Arguments @() -CommandPath $fExpiry -CommandName 'fixture' -Subcommand 'logs' -BoundParameters @{ Expiry = '30d' }
    } catch { $threw19a = $true; $err19a = $_.Exception.Message }
    Assert-True -cond (-not $threw19a) -name 'bound param allowed when subcommand platform permits' -detail $err19a

    $script:_NucleusCliSpecCacheTried = $false
    $script:_NucleusCliSpecCache = $null
    $Expiry = '30d'
    if ($IsWindows) {
      $threw19b = $false
      $err19b = ''
      try {
        $null = Resolve-NucleusArgument -Arguments @() -CommandPath $fExpiry -CommandName 'fixture' -BoundParameters @{ Expiry = '30d' }
      } catch { $threw19b = $true; $err19b = $_.Exception.Message }
      Assert-True -cond $threw19b -name 'natively-bound platform-restricted param rejected on windows' -detail $err19b
      Assert-HasSubstring -haystack $err19b -needle 'not supported on windows' -name 'bound param rejection names platform'
      Assert-HasSubstring -haystack $err19b -needle 'Expiry' -name 'bound param rejection names flag'
    } else {
      $threw19b = $false
      $err19b = ''
      try {
        $null = Resolve-NucleusArgument -Arguments @() -CommandPath $fExpiry -CommandName 'fixture' -BoundParameters @{ Expiry = '30d' }
      } catch { $threw19b = $true; $err19b = $_.Exception.Message }
      Assert-True -cond (-not $threw19b) -name 'natively-bound platform-restricted param accepted on posix host' -detail $err19b
    }

    $script:_NucleusCliSpecCacheTried = $false
    $script:_NucleusCliSpecCache = $null
    $Expiry = '30d'
    $threw19c = $false
    $err19c = ''
    try {
      $null = Resolve-NucleusArgument -Arguments @() -CommandPath $fExpiry -CommandName 'fixture'
    } catch { $threw19c = $true; $err19c = $_.Exception.Message }
    Assert-True -cond (-not $threw19c) -name 'BoundParameters default is backward compatible when omitted' -detail $err19c
  } finally {
    if ($null -eq $savedRoot) { Remove-Item Env:NUCLEUS_REPO_ROOT -ErrorAction SilentlyContinue } else { $env:NUCLEUS_REPO_ROOT = $savedRoot }
    $script:_NucleusCliSpecCacheTried = $false
    $script:_NucleusCliSpecCache = $null
  }

} finally {
  # check-suppress:suppression_doc: temp test dir cleanup must not mask test results
  Remove-Item -Recurse -Force $tempRoot -ErrorAction SilentlyContinue
  foreach ($sr in $specRoots) {
    # check-suppress:suppression_doc: temp test dir cleanup must not mask test results
    Remove-Item -Recurse -Force $sr -ErrorAction SilentlyContinue
  }
}

Write-Output "`n$passed passed, $failed failed"
if ($failed -gt 0) { exit 1 }
exit 0
