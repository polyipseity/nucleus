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
# Execution model: check-pwsh.ps1 groups rules by workaround via
# $RuleWorkaroundMap. The no-workaround group (all rules except AvoidAlias)
# runs first with natural cache population. CachePrePopulation (AvoidAlias)
# runs after dummy injection. This avoids cross-pollution between real and
# dummy CommandInfo entries. Total runtime impact is negligible because PSSA
# already parallelizes rules internally.
#
# === Per-rule timing (30 largest PS1 files, fresh process) ===
# Measured: 2026-07-26 on MacBook (Apple Silicon)
#
# Fresh-process benchmark (each rule run in a separate process with
# IncludeRules isolation; 30 largest files by size):
#
# Scenario                                     Time    Diagnostics  vs Full
# ----                                         ----    -----------  ------
# Full run (all 75 rules)                       36.7s  521          100%
# AvoidAlias only (cold, no pre-pop)            30.6s    0           83%
# AvoidAlias + cache pre-pop                     0.7s    0           46x ↓
# PSUseConsistentIndentation only                0.7s   7935          2%
# PSAlignAssignmentStatement only                0.5s  103           1%
#
# Key finding: PSAvoidUsingCmdletAliases dominates cold-start at 83% of
# total PSSA runtime. Cache pre-pop yields ~46x speedup for this rule
# (30.6s → 0.7s). All other 74 rules combined = ~6s residual.
#
# Per-rule ranking (after warmup, same process, 30 files):
# Rank  Rule                                        Time    Diag
# ----  ----                                        ----    ----
#   1   PSUseConsistentIndentation                   219ms   7935
#   2   PSUseConstrainedLanguageMode                 162ms    327
#   3   PSPossibleIncorrectUsageOfRedirectionOperator 113ms      0
#   4   PSUseSingularNouns                           111ms      0
#   5   PSReviewUnusedParameter                      109ms    188
#   6   PSAvoidAssignmentToAutomaticVariable         109ms      3
#   7   PSPlaceCloseBrace                            108ms    174
#   8   PSUseConsistentParametersKind                107ms      2
#   9   PSUseConsistentWhitespace                    107ms    198
#  10   PSPlaceOpenBrace                             105ms      3
#  11   PSAvoidUsingCmdletAliases (warmed up)         95ms      0
#  ...  (65 other rules, most ~90-110ms)
# Total sum across all 75 rules after warmup: 7.4s
#
# Cache pre-pop eliminates the 30.6s cold-start that makes AvoidAlias
# dominant. After warmup, formatting rules (ConsistentIndentation,
# ConsistentWhitespace) are #1 runtime cost.
#
# Re-measure after each PSScriptAnalyzer or PowerShell version bump.
#
# === AvoidAlias bottleneck analysis ===
# PSAvoidUsingCmdletAliases dominates cold-start (~30s/36s = 83%).
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
#     neither. Both null and type 74 must be pre-populated.
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
