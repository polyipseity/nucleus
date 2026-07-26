# Benchmark: PSScriptAnalyzer warmup + cache pre-population impact
# Measured: 2026-07-25 on MacBook (Apple Silicon), 127 PS1 files
#
# Mode                                               Real
# ----                                               ----
# -SyntaxOnly                                         2.0s
# Full lint (via check-pwsh.ps1, cache + syntax)    24.9s
# Full lint (cache pre-pop)                          20.5s
# Full lint (no cache pre-pop)                       63.1s
#
# Cache pre-population (RemoteCommandInfo injection) yields ~3.1x speedup
# (63.1s → 20.5s). Injects 729 names across 127 files.
#
# PSModulePath scoping is additive (saves ~40s on first pass by reducing
# module-discovery overhead). Together the two optimizations bring a
# full-repo lint from ~100s to ~20s.
#
# === AvoidAlias bottleneck analysis ===
# PSAvoidUsingCmdletAliases is the dominant per-file cost.
# Root cause: MoveNext calls Get-Command for every unique command name,
# though GetCmdletNameFromAlias (O(1) dict lookup) already covers all
# 110/111 aliases with 0 false negatives. The Get-Command calls are entirely
# wasted — they never find an alias in this codebase.
#
# Cache key discrimination (CommandLookupKey):
#   AvoidAlias calls GetCommandInfo with TWO CommandTypes:
#   - null (→All=383 per constructor): for most built-in cmdlets
#   - type 74 (Function|Cmdlet|Filter, hardcoded 0x1F 0x4A in IL): for
#     Get-prefixed variants
#   Pre-populating with type 8 (Cmdlet only) has zero benefit — matches
#   neither. Both null and type 74 must be pre-populated.
#
# RemoteCommandInfo injection (implemented in
# src/scripts/shell/optimize-pssa-cache.ps1) pre-populates the cache with
# both key variants before PSSA rule evaluation, avoiding the slow
# Get-Command path.
#
# Re-measure after each PSScriptAnalyzer or PowerShell version bump.
@{
    Severity = @('Error', 'Warning')
    ExcludeRules = @('PSUseBOMForUnicodeEncodedFile')
}
