# Benchmark: CommandInfo cache pre-population (Phase 1b) impact
# Measured: 2026-07-25 on MacBook (Apple Silicon), 126 PS1 files
#
# Mode                                         Real
# ----                                         ----
# -SyntaxOnly                                  0.60s
# -SyntaxOnly -SkipCachePrepopulation          0.91s
# Full lint (default)                         57.47s
# Full lint -SkipCachePrepopulation           61.69s
#
# Pre-population speeds up full lint by ~4s (enumeration-based Get-Command
# avoids ~28s penalty from unresolvable -Name lookups). Cache hit rate is
# ~30% (118/392 AST names resolved). Re-measure after each PSScriptAnalyzer
# or PowerShell version bump.
@{
    Severity = @('Error', 'Warning')
    ExcludeRules = @('PSUseBOMForUnicodeEncodedFile')
}
