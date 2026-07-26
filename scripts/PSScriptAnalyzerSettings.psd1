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
# Execution model: check-pwsh.ps1 runs rules in two explicit groups.
# Group 1: all rules except PSAvoidUsingCmdletAliases (natural cache).
# Group 2: PSAvoidUsingCmdletAliases (post-dummy-injection, last).
#
# Hybrid pre-population injects real CommandInfo objects for command
# names matching loaded commands before any rule runs. This gives Group 1 rules
# limited cache hits for names resolvable via Get-Command.
# Dummy injection (after Group 1) fills remaining cache gaps via RemoteCommandInfo,
# with TryAdd ensuring real objects survive. Group 1 never sees dummies.
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
# === Exhaustive per-rule benchmark (127 files, fresh process, 3 orderings) ===
# Measured: 2026-07-25 on MacBook (Apple Silicon)
#
# Exhaustive single-rule-in-fresh-process benchmark across all 75 rules, all
# 127 tracked PS1 files, with 3 different rule orderings to isolate order
# effects (forward alphabetical, reverse, random). Each run is an independent
# fresh pwsh process (Import-Module PSScriptAnalyzer, run one rule, exit).
# No warmup, no CachePrePopulation.
#
# 3 inherently slow rules dominate:
# Rule                                    Fwd(ms) Rev(ms) Rand(ms) Diags   Cause
# ----                                    ------- ------- -------- -----   -----
# PSAvoidUsingCmdletAliases                 44957   45599   82492      9   CPU-bound
# PSShouldProcess                           37234   36944   96846      0   CPU-bound
# PSUseCmdletCorrectly                      29442   30199   55646      0   CPU-bound
#
# Totals: fwd=148.6s, rev=169.4s, rand=311.2s (577 total diags across all 75 rules)
#
# Interpretation:
# - PSAvoidUsingCmdletAliases (~45-97s): iterates every command name in every
#   PS1 file and calls GetCommandInfo with TWO CommandTypes values (74 and
#   383) per name. This is the single biggest PSSA cost. CachePrePopulation
#   eliminates it (reduces to <100ms warm).
# - PSShouldProcess (~37-97s): validates that every cmdlet with ShouldProcess
#   support is correctly called in a ShouldProcess scope. Must trace call
#   context for every cmdlet invocation. CPU-bound, no Get-Command dependency.
# - PSUseCmdletCorrectly (~29-56s): checks correct parameter usage for all
#   known cmdlets. Requires full parameter-set resolution per invocation.
#   CPU-bound, no Get-Command dependency.
# - All other 72 rules: 468-598ms each (baseline), no inherent slowness.
#
# Random-order effect: the 3 CPU-bound rules scatter .NET assembly access
# patterns, causing page-cache thrashing for nearby rules. Observed as 13
# rules temporarily inflated to 1-5s (up from 473-546ms baseline). These
# are cache artifacts, not real slowness.#
# === Hybrid real+dummy injection ===
# Measured: 2026-07-26 on MacBook (Apple Silicon), 127 PS1 files
#
# Hybrid = 90 real CmdletInfo/FunctionInfo objects + 673 RemoteCommandInfo
# dummies pre-injected in two phases. Real objects 1st (before no-workaround
# rules), dummies 2nd (before CachePrePopulation group).
#
# Scenario                                     Time   Speedup
# ----                                         ----   -------
# AvoidAlias (cold, no pre-pop)               108.9s     1x
# AvoidAlias (+CachePrePopulation dummies)      0.3s   406x
# AvoidAlias (+hybrid pre-pop)                  0.3s   406x
# UseCmdletCorrectly (cold)                    67.3s     1x
# UseCmdletCorrectly (+hybrid 90 real)         59-67s  ~1.1x*
# UseCmdletCorrectly (100% cache after Avoid)   1.4s    48x
# PSShouldProcess (cold)                       67.4s     1x
# PSShouldProcess (+hybrid)                    67.4s     1x**
#
# * Only 90/763 names matched real commands → 12% cache hit rate.
#   Remaining 673 trigger Get-Command fallthrough (same as cold).
# ** Not cache-dependent — bottleneck is rule logic.
#
# Key conclusion: CachePrePopulation alone solves AvoidAlias. Hybrid adds
# incremental improvement for UseCmdletCorrectly. PSShouldProcess needs
# rule-level profiling, not cache manipulation.
### Re-measure after each PSScriptAnalyzer or PowerShell version bump.
@{
    Severity = @('Error', 'Warning')
    ExcludeRules = @('PSUseBOMForUnicodeEncodedFile')
}
