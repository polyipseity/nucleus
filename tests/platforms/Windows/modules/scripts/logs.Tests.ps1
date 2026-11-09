<#
.SYNOPSIS
  Pester tests for scripts/logs.ps1, the Windows half of nucleus-logs.

.DESCRIPTION
  The suite runs the real script in a child pwsh against a temporary log root, so
  the assertions cover the contract a caller sees: one canonical JSON line per
  append, a label that never rewrites existing history, concurrent appends that
  no line is lost from, copy-truncate rotation with a gzip archive, and expiry of
  archives past the retention window.

  Run with: pwsh -NoProfile -Command "Invoke-Pester tests/platforms/Windows/modules/scripts/logs.Tests.ps1"
#>

BeforeAll {
  # check-suppress:suppression_doc: deterministic color state -- color init runs
  # at import, so NO_COLOR pins plain output for the whole suite.
  $env:NO_COLOR = '1'

  $script:PwshExe = (Get-Command pwsh).Source
  # WHY forward slashes: the suite also runs on POSIX, where a backslash is a
  # literal filename character rather than a separator.
  $script:RepoRoot = (Resolve-Path -Path (Join-Path -Path $PSScriptRoot -ChildPath '../../../../..')).Path
  $script:LogsPs1 = Join-Path -Path $script:RepoRoot -ChildPath 'scripts/logs.ps1'
  $script:Work = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("nucleus-logs-" + [guid]::NewGuid().ToString())
  $null = New-Item -ItemType Directory -Path $script:Work -Force

  $env:NUCLEUS_REPO_ROOT = $script:RepoRoot
  $env:NUCLEUS_LOG_DIR = $script:Work

  function Invoke-LogCommand {
    param(
      [Parameter(Mandatory)][string[]]$Arguments,
      [string]$InputLine,
      [hashtable]$Environment = @{}
    )

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $script:PwshExe
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.RedirectStandardInput = $true
    foreach ($argument in @('-NoProfile', '-NoLogo', '-File', $script:LogsPs1) + $Arguments) {
      $startInfo.ArgumentList.Add($argument)
    }
    # WHY per-case variables: a case that needs a log root the suite does not use,
    # such as a directory that must not exist, sets it here rather than on the
    # suite's own environment.
    foreach ($name in $Environment.Keys) {
      $startInfo.Environment[$name] = [string]$Environment[$name]
    }
    $process = [System.Diagnostics.Process]::Start($startInfo)
    # WHY: both streams are read asynchronously; draining one to the end while the
    # child fills the other stream's buffer can deadlock.
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    if ($InputLine) { $process.StandardInput.WriteLine($InputLine) }
    $process.StandardInput.Close()
    $process.WaitForExit()
    return [pscustomobject]@{
      Stdout   = $stdout.Result
      Stderr   = $stderr.Result
      ExitCode = $process.ExitCode
    }
  }

  function Get-LogLine {
    param([Parameter(Mandatory)][string]$LogName)
    $path = Join-Path -Path $script:Work -ChildPath "$LogName.log"
    return @(Get-Content -LiteralPath $path)
  }
}

AfterAll {
  if (Test-Path -LiteralPath $script:Work) {
    Remove-Item -LiteralPath $script:Work -Recurse -Force
  }
}

Describe 'nucleus-logs append' {
  It 'writes one line carrying every canonical key' {
    $result = Invoke-LogCommand -Arguments @('append', '-Log', 'decisions') -InputLine '{"id":"one","kind":"decision"}'
    $result.ExitCode | Should -Be 0

    $lines = @(Get-LogLine -LogName "decisions")
    $lines.Count | Should -Be 1

    $logEvent = $lines[0] | ConvertFrom-Json
    foreach ($key in @('ts', 'id', 'kind', 'harness', 'decision', 'source', 'filter', 'rule', 'latency_ms', 'summary', 'digest')) {
      $logEvent.PSObject.Properties.Name | Should -Contain $key
    }
    $logEvent.id | Should -Be 'one'
  }

  It 'refuses an event over the 4096-byte limit' {
    $big = 'x' * 5000
    $result = Invoke-LogCommand -Arguments @('append', '-Log', 'decisions') -InputLine ('{"id":"big","summary":"' + $big + '"}')
    $result.ExitCode | Should -Not -Be 0
    ($result.Stderr -join '') | Should -BeLike '*4096*'
  }

  It 'refuses a second event line on stdin' {
    # WHY: scripts/logs.sh dies on the same input, because a caller that wrote two
    # events would otherwise have one appended and the other dropped in silence.
    $result = Invoke-LogCommand -Arguments @('append', '-Log', 'two-lines') -InputLine ("{`"id`":`"a1`"}`n{`"id`":`"a2`"}")

    $result.ExitCode | Should -Not -Be 0
    ($result.Stderr -join '') | Should -BeLike '*expected exactly one event line on stdin*'
    (Test-Path -LiteralPath (Join-Path -Path $script:Work -ChildPath 'two-lines.log')) | Should -BeFalse
  }

  It 'leaves no lock sidecar behind after a completed append' {
    # WHY: the sidecar only serializes appenders, so a leftover one is a file
    # nothing owns: it never rotates, never expires, and sits in the log root
    # the stats reader walks.
    $result = Invoke-LogCommand -Arguments @('append', '-Log', 'sidecar') -InputLine '{"id":"s1","kind":"decision"}'
    $result.ExitCode | Should -Be 0

    @(Get-ChildItem -LiteralPath $script:Work -Filter '*.lock' -File) | Should -HaveCount 0
  }
}

Describe 'nucleus-logs label' {
  It 'appends a kind=label event to the harness log and leaves earlier lines untouched' {
    $null = Invoke-LogCommand -Arguments @('label', '-Id', 'seed', '-Verdict', 'correct', '-Note', 'seed event')
    $before = @(Get-LogLine -LogName 'harness')
    $before.Count | Should -Be 1

    $result = Invoke-LogCommand -Arguments @('label', '-Id', 'one', '-Verdict', 'false-deny', '-Note', 'reviewed by hand')
    $result.ExitCode | Should -Be 0

    $after = @(Get-LogLine -LogName 'harness')
    $after.Count | Should -Be ($before.Count + 1)
    for ($index = 0; $index -lt $before.Count; $index++) {
      $after[$index] | Should -Be $before[$index]
    }

    $label = $after[-1] | ConvertFrom-Json
    $label.kind | Should -Be 'label'
    $label.id | Should -Be 'one'
    $label.verdict | Should -Be 'false-deny'
    $label.note | Should -Be 'reviewed by hand'
    $label.source | Should -Be 'none'
  }

  It 'rejects -Scope, which the other subcommands accept and label does not' {
    # WHY: label always writes to the user root, so a -Scope it silently ignored
    # claimed a destination the event never reached. scripts/logs.sh has no
    # --scope on label for the same reason.
    $before = @(Get-LogLine -LogName 'harness').Count
    $result = Invoke-LogCommand -Arguments @('label', '-Id', 'scoped', '-Verdict', 'correct', '-Scope', 'system')

    $result.ExitCode | Should -Be 1
    ($result.Stderr -join '') | Should -BeLike "*unsupported option '-Scope' for label*"
    @(Get-LogLine -LogName 'harness').Count | Should -Be $before
  }
}

Describe 'nucleus-logs name validation' {
  It 'rejects an empty log name without creating a lock in the current directory' {
    Push-Location -Path $script:RepoRoot
    try {
      $command = ". '$($script:LogsPs1)'; Add-NucleusLogEvent -LogName '' -Event @{ id = 'x' }"
      & $script:PwshExe -NoProfile -NonInteractive -Command $command > $null 2>&1
      $LASTEXITCODE | Should -Not -Be 0
      (Test-Path -LiteralPath (Join-Path -Path $script:RepoRoot -ChildPath '.lock')) | Should -BeFalse
      (Test-Path -LiteralPath (Join-Path -Path $script:RepoRoot -ChildPath '.log')) | Should -BeFalse
    } finally {
      Pop-Location
    }
  }
}

Describe 'nucleus-logs concurrency' {
  It 'keeps every line of 12 concurrent appends parseable' {
    $processes = @()
    for ($i = 1; $i -le 12; $i++) {
      $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
      $startInfo.FileName = $script:PwshExe
      $startInfo.UseShellExecute = $false
      $startInfo.RedirectStandardOutput = $true
      $startInfo.RedirectStandardError = $true
      $startInfo.RedirectStandardInput = $true
      foreach ($argument in @('-NoProfile', '-NoLogo', '-File', $script:LogsPs1, 'append', '-Log', 'concurrent')) {
        $startInfo.ArgumentList.Add($argument)
      }
      $process = [System.Diagnostics.Process]::Start($startInfo)
      $null = $process.StandardOutput.ReadToEndAsync()
      $null = $process.StandardError.ReadToEndAsync()
      $process.StandardInput.WriteLine(('{{"id":"c{0:d2}","kind":"concurrent"}}' -f $i))
      $process.StandardInput.Close()
      $processes += $process
    }
    foreach ($process in $processes) {
      $process.WaitForExit()
      $process.ExitCode | Should -Be 0
    }

    $lines = @(Get-LogLine -LogName "concurrent")
    $lines.Count | Should -Be 12
    $ids = @()
    foreach ($line in $lines) {
      $logEvent = $line | ConvertFrom-Json
      $logEvent.kind | Should -Be 'concurrent'
      $ids += $logEvent.id
    }
    ($ids | Sort-Object -Unique).Count | Should -Be 12
  }
}

Describe 'nucleus-logs tolerates a native writer' {
  It 'appends while another handle holds the log open for writing' {
    $path = Join-Path $script:Work 'native.log'
    # WHY this holder: a service redirecting stdout into the log holds the file
    # open for writing. The append must wait on the lock sidecar, never on the
    # log itself, or every event would time out behind the native writer.
    $holder = [System.IO.FileStream]::new(
      $path,
      [System.IO.FileMode]::Append,
      [System.IO.FileAccess]::Write,
      [System.IO.FileShare]::ReadWrite)
    try {
      $nativeBytes = [System.Text.Encoding]::UTF8.GetBytes("native line`n")
      $holder.Write($nativeBytes, 0, $nativeBytes.Length)
      $holder.Flush()

      $result = Invoke-LogCommand -Arguments @('append', '-Log', 'native') -InputLine '{"id":"n1","kind":"decision"}'
      $result.ExitCode | Should -Be 0
      (Get-Content -LiteralPath $path).Count | Should -Be 2
    } finally {
      $holder.Dispose()
    }
  }
}

Describe 'nucleus-logs tail' {
  It 'returns the newest event line rather than an empty success' {
    $null = Invoke-LogCommand -Arguments @('append', '-Log', 'tail-check') -InputLine '{"id":"t1","kind":"decision","summary":"first"}'
    $null = Invoke-LogCommand -Arguments @('append', '-Log', 'tail-check') -InputLine '{"id":"t2","kind":"decision","summary":"second"}'

    $result = Invoke-LogCommand -Arguments @('tail', '-Log', 'tail-check', '-Lines', '1')
    $result.ExitCode | Should -Be 0
    # WHY the content assertion: a swallowed binding error exits 0 with no output,
    # so the exit code alone cannot cover this path.
    $result.Stdout | Should -Not -BeNullOrEmpty
    # WHY the summary words: -BeLike is case-insensitive, so an id assertion on
    # "t1"/"t2" matches the ISO timestamp's "T1".
    ($result.Stdout -join "`n") | Should -BeLike '*second*'
    ($result.Stdout -join "`n") | Should -Not -BeLike '*first*'
  }
}

Describe 'nucleus-logs rotate and expire' {
  It 'archives an oversized log and truncates it in place' {
    $path = Join-Path -Path $script:Work -ChildPath 'rotate-me.log'
    $payload = '{"id":"rot","summary":"' + ('y' * 3000) + '"}'
    Set-Content -LiteralPath $path -Value $payload -NoNewline
    $null = Add-Content -LiteralPath $path -Value ([Environment]::NewLine)

    $result = Invoke-LogCommand -Arguments @('rotate', '-MaxSize', '1024', '-MaxFiles', '4', '-Compress', 'true')
    $result.ExitCode | Should -Be 0

    # WHY the .1.log naming: nucleus-logs names Windows archives
    # <base>.<N>.log.gz, unlike the POSIX <log>.log.<N>.gz form.
    (Test-Path -LiteralPath (Join-Path -Path $script:Work -ChildPath 'rotate-me.1.log.gz')) | Should -BeTrue
    (Get-Item -LiteralPath $path).Length | Should -Be 0

    $inputStream = [System.IO.File]::OpenRead((Join-Path -Path $script:Work -ChildPath 'rotate-me.1.log.gz'))
    try {
      $gzip = [System.IO.Compression.GZipStream]::new($inputStream, [System.IO.Compression.CompressionMode]::Decompress)
      try {
        $reader = [System.IO.StreamReader]::new($gzip)
        try {
          ($reader.ReadToEnd() | ConvertFrom-Json).id | Should -Be 'rot'
        } finally { $reader.Dispose() }
      } finally { $gzip.Dispose() }
    } finally { $inputStream.Dispose() }
  }

  It 'shows events from an uncompressed archive' {
    # WHY: with compression off, rotation leaves <base>.1.log as plain text, and a
    # reader that always inflates would fail on every show.
    $path = Join-Path -Path $script:Work -ChildPath 'plain.log'
    Set-Content -LiteralPath $path -Value ('{"id":"rot","summary":"' + ('y' * 3000) + '"}')

    $result = Invoke-LogCommand -Arguments @('rotate', '-MaxSize', '1024', '-Compress', 'false')
    $result.ExitCode | Should -Be 0
    (Test-Path -LiteralPath (Join-Path -Path $script:Work -ChildPath 'plain.1.log')) | Should -BeTrue

    $show = Invoke-LogCommand -Arguments @('show', '-Log', 'plain', '-Json')
    $show.ExitCode | Should -Be 0
    $ids = @(($show.Stdout -join "`n") | ConvertFrom-Json).id
    $ids | Should -Contain 'rot'
  }

  It 'does not list an uncompressed archive as its own log' {
    $stats = Invoke-LogCommand -Arguments @('stats', '-Json')
    $stats.ExitCode | Should -Be 0
    $names = @(($stats.Stdout -join "`n") | ConvertFrom-Json).log
    $names | Should -Not -Contain 'plain.1'
  }

  It 'shifts an existing archive rather than rotating it in place' {
    # WHY the archive is seeded over MaxSize: rotation scans *.log, so an archive
    # named <base>.1.log matches too, and a rotation that reads it as a live log
    # renames it to <base>.1.1.log and then shifts the truncated file over the
    # history it should have kept.
    $live = Join-Path -Path $script:Work -ChildPath 'excl.log'
    $archive = Join-Path -Path $script:Work -ChildPath 'excl.1.log'
    $livePayload = 'LIVE-' * 300
    $archivePayload = 'OLD-' * 300
    Set-Content -LiteralPath $live -Value $livePayload -NoNewline
    Set-Content -LiteralPath $archive -Value $archivePayload -NoNewline

    $result = Invoke-LogCommand -Arguments @('rotate', '-MaxSize', '1024', '-MaxFiles', '2', '-Compress', 'false')
    $result.ExitCode | Should -Be 0

    (Get-Content -LiteralPath (Join-Path -Path $script:Work -ChildPath 'excl.2.log') -Raw) | Should -Be $archivePayload
    (Get-Content -LiteralPath $archive -Raw) | Should -Be $livePayload
    (Get-Item -LiteralPath $live).Length | Should -Be 0
    (Test-Path -LiteralPath (Join-Path -Path $script:Work -ChildPath 'excl.1.1.log')) | Should -BeFalse
  }

  It 'removes an archive older than the expiry and keeps a fresh one' {
    $old = Join-Path -Path $script:Work -ChildPath 'expire-me.log.1.gz'
    $fresh = Join-Path -Path $script:Work -ChildPath 'expire-me.log.2.gz'
    foreach ($target in @($old, $fresh)) {
      $bytes = [System.Text.Encoding]::UTF8.GetBytes('{"id":"x"}')
      $fileStream = [System.IO.File]::Create($target)
      try {
        $gzipStream = [System.IO.Compression.GZipStream]::new($fileStream, [System.IO.Compression.CompressionMode]::Compress)
        try { $gzipStream.Write($bytes, 0, $bytes.Length) } finally { $gzipStream.Dispose() }
      } finally { $fileStream.Dispose() }
    }
    (Get-Item -LiteralPath $old).LastWriteTime = (Get-Date).AddDays(-30)

    $result = Invoke-LogCommand -Arguments @('expire', '-Expiry', '7d')
    $result.ExitCode | Should -Be 0

    (Test-Path -LiteralPath $old) | Should -BeFalse
    (Test-Path -LiteralPath $fresh) | Should -BeTrue
  }

  It 'is a no-op on a missing log directory' {
    $missing = Join-Path -Path $script:Work -ChildPath ('missing-' + [guid]::NewGuid().ToString('N'))
    # WHY the system scope: every other case rotates the shared user root, so the
    # only way to hand the runner a root that does not exist is the scope this case
    # points at its own absent path.
    # WHY the dry run first: it proves the override reached the child, so the
    # rotation below cannot fall back to the host's real system log root.
    $dry = Invoke-LogCommand -Arguments @('rotate', '-Scope', 'system', '-DryRun') -Environment @{ NUCLEUS_SYSTEM_LOG_DIR = $missing }
    ($dry.Stdout -join '') | Should -BeLike "*$missing*"

    $result = Invoke-LogCommand -Arguments @('rotate', '-Scope', 'system', '-MaxSize', '10', '-MaxFiles', '2', '-Compress', 'false') -Environment @{ NUCLEUS_SYSTEM_LOG_DIR = $missing }

    $result.ExitCode | Should -Be 0
    (Test-Path -LiteralPath $missing) | Should -BeFalse
  }

  It 'leaves a log under the size limit untouched' {
    $dir = Join-Path -Path $script:Work -ChildPath 'under-limit'
    $null = New-Item -ItemType Directory -Path $dir -Force
    $path = Join-Path -Path $dir -ChildPath 'keep.log'
    Set-Content -LiteralPath $path -Value 'small content' -NoNewline

    $result = Invoke-LogCommand -Arguments @('rotate', '-MaxSize', '100000', '-MaxFiles', '2', '-Compress', 'false')
    $result.ExitCode | Should -Be 0

    (Get-Content -LiteralPath $path -Raw) | Should -Be 'small content'
    (Test-Path -LiteralPath (Join-Path -Path $dir -ChildPath 'keep.1.log')) | Should -BeFalse
  }

  It 'compresses the archive when -Compress is not given' {
    $dir = Join-Path -Path $script:Work -ChildPath 'default-compress'
    $null = New-Item -ItemType Directory -Path $dir -Force
    $path = Join-Path -Path $dir -ChildPath 'test.log'
    $payload = '{"id":"c","summary":"' + ('y' * 300) + '"}'
    Set-Content -LiteralPath $path -Value $payload -NoNewline

    # WHY no -Compress: the schema default is what nucleus-gc inherits, so a case
    # that always passes the flag would leave the default unproven.
    $result = Invoke-LogCommand -Arguments @('rotate', '-MaxSize', '10', '-MaxFiles', '2')
    $result.ExitCode | Should -Be 0

    $archive = Join-Path -Path $dir -ChildPath 'test.1.log.gz'
    (Test-Path -LiteralPath $archive -PathType Leaf) | Should -BeTrue
    (Test-Path -LiteralPath (Join-Path -Path $dir -ChildPath 'test.1.log')) | Should -BeFalse
    $inputStream = [System.IO.File]::OpenRead($archive)
    try {
      $gzip = [System.IO.Compression.GZipStream]::new($inputStream, [System.IO.Compression.CompressionMode]::Decompress)
      try {
        $reader = [System.IO.StreamReader]::new($gzip)
        try {
          ($reader.ReadToEnd() | ConvertFrom-Json).id | Should -Be 'c'
        } finally { $reader.Dispose() }
      } finally { $gzip.Dispose() }
    } finally { $inputStream.Dispose() }
  }

  It 'copies the log to its first archive and truncates it in place' {
    $dir = Join-Path -Path $script:Work -ChildPath 'copy-truncate'
    $null = New-Item -ItemType Directory -Path $dir -Force
    $path = Join-Path -Path $dir -ChildPath 'test.log'
    $payload = 'a' * 100
    Set-Content -LiteralPath $path -Value $payload -NoNewline

    $result = Invoke-LogCommand -Arguments @('rotate', '-MaxSize', '10', '-MaxFiles', '2', '-Compress', 'false')
    $result.ExitCode | Should -Be 0

    (Get-Content -LiteralPath (Join-Path -Path $dir -ChildPath 'test.1.log') -Raw) | Should -Be $payload
    # WHY the live file is asserted twice: copy-truncate keeps the path a service
    # holds open, so the log must still exist and carry nothing.
    (Test-Path -LiteralPath $path -PathType Leaf) | Should -BeTrue
    (Get-Item -LiteralPath $path).Length | Should -Be 0
  }

  It 'shifts the archives through MaxFiles' {
    $dir = Join-Path -Path $script:Work -ChildPath 'shift'
    $null = New-Item -ItemType Directory -Path $dir -Force
    $payload = 'a' * 100
    Set-Content -LiteralPath (Join-Path -Path $dir -ChildPath 'test.log') -Value $payload -NoNewline
    Set-Content -LiteralPath (Join-Path -Path $dir -ChildPath 'test.1.log') -Value 'old1' -NoNewline
    Set-Content -LiteralPath (Join-Path -Path $dir -ChildPath 'test.2.log') -Value 'old2' -NoNewline

    $result = Invoke-LogCommand -Arguments @('rotate', '-MaxSize', '10', '-MaxFiles', '3', '-Compress', 'false')
    $result.ExitCode | Should -Be 0

    # WHY the bytes: an existence check passes even when the shift overwrites one
    # archive with another, so every slot names the content it must hold.
    (Get-Content -LiteralPath (Join-Path -Path $dir -ChildPath 'test.1.log') -Raw) | Should -Be $payload
    (Get-Content -LiteralPath (Join-Path -Path $dir -ChildPath 'test.2.log') -Raw) | Should -Be 'old1'
    (Get-Content -LiteralPath (Join-Path -Path $dir -ChildPath 'test.3.log') -Raw) | Should -Be 'old2'
  }

  It 'drops the oldest archive when the log is already at MaxFiles' {
    $dir = Join-Path -Path $script:Work -ChildPath 'drop'
    $null = New-Item -ItemType Directory -Path $dir -Force
    $payload = 'a' * 100
    Set-Content -LiteralPath (Join-Path -Path $dir -ChildPath 'test.log') -Value $payload -NoNewline
    Set-Content -LiteralPath (Join-Path -Path $dir -ChildPath 'test.1.log') -Value 'old1' -NoNewline
    Set-Content -LiteralPath (Join-Path -Path $dir -ChildPath 'test.2.log') -Value 'old2' -NoNewline
    Set-Content -LiteralPath (Join-Path -Path $dir -ChildPath 'test.3.log') -Value 'old3' -NoNewline

    $result = Invoke-LogCommand -Arguments @('rotate', '-MaxSize', '10', '-MaxFiles', '3', '-Compress', 'false')
    $result.ExitCode | Should -Be 0

    (Test-Path -LiteralPath (Join-Path -Path $dir -ChildPath 'test.4.log')) | Should -BeFalse
    (Get-Content -LiteralPath (Join-Path -Path $dir -ChildPath 'test.2.log') -Raw) | Should -Be 'old1'
    # WHY old3 is asserted absent: dropping the oldest means the archive that held
    # old3 is gone, not that its slot was reused by a newer one.
    @(Get-ChildItem -LiteralPath $dir -File | Where-Object { (Get-Content -LiteralPath $_.FullName -Raw) -eq 'old3' }) | Should -HaveCount 0
  }

  It 'rotates a log in a subdirectory' {
    $dir = Join-Path -Path (Join-Path -Path $script:Work -ChildPath 'nested') -ChildPath 'subsvc'
    $null = New-Item -ItemType Directory -Path $dir -Force
    $path = Join-Path -Path $dir -ChildPath 'combined.log'
    $payload = 'a' * 100
    Set-Content -LiteralPath $path -Value $payload -NoNewline

    $result = Invoke-LogCommand -Arguments @('rotate', '-MaxSize', '10', '-MaxFiles', '2', '-Compress', 'false')
    $result.ExitCode | Should -Be 0

    (Get-Content -LiteralPath (Join-Path -Path $dir -ChildPath 'combined.1.log') -Raw) | Should -Be $payload
    (Get-Item -LiteralPath $path).Length | Should -Be 0
  }

  It 'never touches a file without the .log extension' {
    $dir = Join-Path -Path $script:Work -ChildPath 'extension'
    $null = New-Item -ItemType Directory -Path $dir -Force
    $path = Join-Path -Path $dir -ChildPath 'data.txt'
    Set-Content -LiteralPath $path -Value ('a' * 100) -NoNewline

    $result = Invoke-LogCommand -Arguments @('rotate', '-MaxSize', '10', '-MaxFiles', '2', '-Compress', 'false')
    $result.ExitCode | Should -Be 0

    (Get-Content -LiteralPath $path -Raw) | Should -Be ('a' * 100)
    (Test-Path -LiteralPath (Join-Path -Path $dir -ChildPath 'data.1.txt')) | Should -BeFalse
  }

  It 'fails loudly when a log cannot be written' -Skip:$IsWindows {
    $dir = Join-Path -Path $script:Work -ChildPath 'unwritable'
    $null = New-Item -ItemType Directory -Path $dir -Force
    $path = Join-Path -Path $dir -ChildPath 'test.log'
    Set-Content -LiteralPath $path -Value ('a' * 100) -NoNewline
    # WHY POSIX-only: the read-only signal here is a mode bit, which only POSIX
    # enforces. A Windows host needs an ACL deny that this suite does not set, so the
    # case is skipped there rather than claiming a parity it does not have.
    chmod 0444 $path
    try {
      $result = Invoke-LogCommand -Arguments @('rotate', '-MaxSize', '10', '-MaxFiles', '2', '-Compress', 'false')
    } finally {
      chmod 0644 $path
    }

    # WHY the message: a rotation that skips an unwritable log loses history
    # silently, so the CLI has to fail and name the file.
    $result.ExitCode | Should -Not -Be 0
    ($result.Stderr -join '') | Should -BeLike '*write access*'
    (Get-Item -LiteralPath $path).Length | Should -Be 100

    # WHY an append to an unwritable log: the sidecar is taken before the log is
    # opened, so only a failed append proves the finally removes it. Without that,
    # the failure path leaves <log>.log.lock in the log root for good.
    $appendPath = Join-Path -Path $script:Work -ChildPath 'append-fail.log'
    Set-Content -LiteralPath $appendPath -Value 'x' -NoNewline
    chmod 0444 $appendPath
    try {
      $failed = Invoke-LogCommand -Arguments @('append', '-Log', 'append-fail') -InputLine '{"id":"f1","kind":"decision"}'
    } finally {
      chmod 0644 $appendPath
    }
    $failed.ExitCode | Should -Not -Be 0
    @(Get-ChildItem -LiteralPath $script:Work -Filter '*.lock' -File) | Should -HaveCount 0
    @(Get-ChildItem -LiteralPath $dir -Filter '*.lock' -File) | Should -HaveCount 0
  }
}

Describe 'nucleus-logs help' {
  It 'prints help and exits 0' {
    $result = Invoke-LogCommand -Arguments @('-Help')
    $result.ExitCode | Should -Be 0
    ($result.Stdout -join '') | Should -BeLike '*nucleus-logs*'
  }
}
