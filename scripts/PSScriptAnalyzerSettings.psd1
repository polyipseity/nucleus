# Benchmark: CommandInfo cache pre-population (Phase 1b) impact
# Measured: 2026-07-25 on MacBook (Apple Silicon), 126 PS1 files
#
# Mode                                         Real    User    Sys
# ----                                         ----    ----    ---
# -SyntaxOnly                                  0.80s   0.48s   1.26s
# -SyntaxOnly -SkipCachePrepopulation          0.75s   0.44s   1.25s
# Full lint (default)                        105.60s  13.98s 111.34s
# Full lint -SkipCachePrepopulation           77.27s  11.38s  88.10s
#
# Pre-population adds ~0.05s overhead to syntax-only (Phase 1) but the
# full-lint baseline (77s) vs pre-populated (106s) suggests the current
# reflection injection is not yielding the expected speedup. Re-measure
# after each PSScriptAnalyzer or PowerShell version bump.
@{
    Severity = @('Error', 'Warning')
    ExcludeRules = @('PSUseBOMForUnicodeEncodedFile')
}
