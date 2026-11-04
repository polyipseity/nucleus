# repository-policy.awk — pattern scans shared by check steps 12 and 13.
#
# Default mode (no -v mode): heredoc size detector for the embedded-content
# policy; flags heredocs with more than 30 content lines.
#
# Logging-format mode (-v mode=logging-format): enforces the unified logging
# format standard (see .agents/instructions/logging.instructions.md):
#   - raw ANSI escapes (\033[, \e[, \x1b[) and tput outside the shared
#     color-helper allowlist, across tracked .sh/.zsh/.ps1/.psm1
#   - echo(1) -e flag in tracked .sh
#   - char-27 ([char]27) and backtick-e escapes in tracked .ps1/.psm1
#
# Skip-constructs mode (-v mode=skip-constructs): fails on any removed skip
# construct (skip_step, Skip-Step, Invoke-SkippedStep, --skip-steps, -SkipStep,
# return 2, SKIPPED, -SkipMessage, assert_skip, TESTS_SKIPPED) under src/scripts/,
# scripts/ or tests/. The two runners document the declared-applicability
# contract, and this file plus the two gate steps carry the pattern list, so all
# of them are excluded here.
# The word "skip" in prose stays legal; only the named constructs match.
#
# Log-capture mode (-v mode=log-capture): one pass over the service definition
# files, enforcing the stdout.log/stderr.log pair
# (output-handling.instructions.md): a capture directive that sends a stream to
# /dev/null, a merged-stream redirection, and a file that captures one stream of
# a directive family but not the other, for launchd and systemd separately.
#
# Activation-naming mode (-v mode=activation-naming): extracts the entry
# definitions inside `<namespace> = { ... };` blocks as "file:line:name"
# records, one record per line. The step owns the policy (kebab-case, the
# forbidden prefix, the macos- requirement); this mode only reports what the
# blocks define, so the step can sort and de-duplicate the records.

# Report one file's log-capture findings, in the order the per-rule greps
# produced them: discards, then merges, then the two presence checks. Order is
# part of the contract, so a merged redirection on an earlier line than a
# discard is still reported second.
function report_capture_pair(   i) {
  for (i = 1; i <= _cap_discards; i++)
    printf "log capture pair: '%s' discards a stream to /dev/null; capture stdout.log and stderr.log instead (output-handling.instructions.md)\n", _cap_discard[i]
  for (i = 1; i <= _cap_merges; i++)
    printf "log capture pair: '%s' merges stdout and stderr; use 1>> and 2>> into stdout.log and stderr.log\n", _cap_merge[i]
  if (_cap_launchd_out != _cap_launchd_err)
    printf "log capture pair: '%s' declares only one of StandardOutPath/StandardErrorPath; declare both or neither\n", _cap_file
  if (_cap_systemd_out != _cap_systemd_err)
    printf "log capture pair: '%s' declares only one of StandardOutput/StandardError; declare both or neither\n", _cap_file
}

# Per-file state, reset at every file: a path with several services is normal,
# so only the lone-stream case is a violation. The two families are tracked
# apart because launchd and systemd spell the same intent differently.
mode == "log-capture" && FNR == 1 {
  if (_cap_file != "") report_capture_pair()
  _cap_file = FILENAME
  _cap_discards = 0
  _cap_merges = 0
  _cap_launchd_out = 0
  _cap_launchd_err = 0
  _cap_systemd_out = 0
  _cap_systemd_err = 0
}
mode == "log-capture" {
  if ($0 ~ /(StandardOutPath|StandardErrorPath|StandardOutput|StandardError)[[:space:]]*=[[:space:]]*"\/dev\/null"/)
    _cap_discard[++_cap_discards] = FILENAME ":" FNR ":" $0
  if (index($0, "*>>"))
    _cap_merge[++_cap_merges] = FILENAME ":" FNR ":" $0
  if (index($0, "StandardOutPath")) _cap_launchd_out = 1
  if (index($0, "StandardErrorPath")) _cap_launchd_err = 1
  if ($0 ~ /StandardOutput[[:space:]]*=/) _cap_systemd_out = 1
  if ($0 ~ /StandardError[[:space:]]*=/) _cap_systemd_err = 1
}
END {
  if (mode == "log-capture" && _cap_file != "") report_capture_pair()
}

BEGIN {
  if (mode == "activation-naming") {
    _an_ns_start = "(home\\.activation|system\\.activationScripts|nucleus\\.terminalActivations)[[:space:]]*=[^;]*[{]"
    # An activation entry carries a lib wrapper, or leaves its value on the next
    # line. That excludes the region's other lines that look like assignments,
    # such as `config = {` inside a value.
    _an_entry = "^[[:space:]]*[A-Za-z0-9_-]+(\\.[A-Za-z0-9_-]+)?[[:space:]]*=[[:space:]]*(lib\\.(mkIf|mkAfter|mkBefore|mkForce|mkOverride|mkOrder|hm\\.dag\\.entry(A|Before|Order|After))|[[:space:]]*$)"
  }
}

# Count one character in a line. Braces inside strings count, because the .ps1
# twin tallies them per line rather than parsing: both twins have to read one
# tree into one record set.
function count_char(text, ch,   i, count) {
  count = 0
  for (i = 1; i <= length(text); i++)
    if (substr(text, i, 1) == ch) count++
  return count
}

# The region opens on a namespace attrset line and closes when its brace depth
# returns to zero, which is how 12-repo-policy-pattern.ps1 tracks it. A nested
# attrset therefore keeps the region open, and the entries after its close are
# still scanned.
mode == "activation-naming" && FNR == 1 {
  _an_block = 0
  _an_depth = 0
}
mode == "activation-naming" {
  if (!_an_block && $0 ~ _an_ns_start) {
    _an_block = 1
    _an_depth = 0
  }
  if (_an_block) {
    if ($0 ~ _an_entry) {
      _an_name = $0
      sub(/^[[:space:]]*/, "", _an_name)
      sub(/[^A-Za-z0-9_-].*$/, "", _an_name)
      print FILENAME ":" FNR ":" _an_name
    }
    _an_depth += count_char($0, "{") - count_char($0, "}")
    if (_an_depth <= 0) {
      _an_block = 0
      _an_depth = 0
    }
  }
}

mode == "" && FNR == 1 { in_heredoc = 0 }
mode == "" && !in_heredoc && match($0, /<<-?[ \t]*["\047\\]?[A-Za-z_][A-Za-z0-9_]*/) {
  op = substr($0, RSTART, RLENGTH)
  tag = op
  sub(/^<<-?[ \t]*["\047\\]?/, "", tag)
  dash = (substr(op, 3, 1) == "-")
  in_heredoc = 1
  start_line = FNR
  body = 0
  next
}
mode == "" && in_heredoc {
  if (dash && $0 ~ "^[ \t]*" tag "[ \t]*$") { in_heredoc = 0 }
  else if (!dash && $0 ~ "^" tag "[ \t]*$") { in_heredoc = 0 }
  else { body++; next }
  if (body > 30) print FILENAME ":" start_line ": heredoc " tag " has " body " content lines (limit 30)"
}

mode == "logging-format" && FNR == 1 {
  # Leaf-match allowlist: the shared color helpers, their tests, and the log
  # sanitizer are the only sanctioned ANSI emitters. WHY:
  # Invoke-LogManagement.ps1 is the log sanitizer (it must reference ESC
  # patterns to strip them) and its tests feed ESC input, so both join the
  # allowlist alongside the helper modules and their tests.
  allowlisted = (FILENAME ~ /(^|\/)(lib|step-runner|test-lib)\.(sh|ps1)$/ ||
                 FILENAME ~ /(^|\/)Format-NucleusOutput(\.psm1|\.Tests\.ps1)$/ ||
                 FILENAME ~ /(^|\/)Invoke-LogManagement\.ps1$/ ||
                 FILENAME ~ /(^|\/)log-management\.Tests\.ps1$/)
}
mode == "logging-format" && !allowlisted {
  if ($0 ~ /\\033\[/ || $0 ~ /\\e\[/ || $0 ~ /\\x1b\[/)
    print FILENAME ":" FNR ": raw ANSI escape literal (use shared color helpers)"
  if ($0 ~ /(^|[^A-Za-z0-9_])tput([^A-Za-z0-9_]|$)/)
    print FILENAME ":" FNR ": terminal capability query (use shared color helpers)"
  if (FILENAME ~ /\.sh$/ && $0 ~ /(^|[^A-Za-z0-9_])echo[ \t]+-e([^A-Za-z0-9_]|$)/)
    print FILENAME ":" FNR ": echo dash-e flag (use printf with %b)"
  if (FILENAME ~ /\.ps1$/ || FILENAME ~ /\.psm1$/) {
    if ($0 ~ /\[char\]27/)
      print FILENAME ":" FNR ": char-27 escape literal (use PSStyle helpers)"
    # An ESC escape is a backtick-e that ends the token; inline code such as
    # `enable` continues with an identifier character.
    if ($0 ~ /`e([^A-Za-z0-9_]|$)/)
      print FILENAME ":" FNR ": backtick-e escape literal (use PSStyle helpers)"
  }
}

function report_skip_construct(construct) {
  print FILENAME ":" FNR ": removed skip mechanism '" construct "'; declare applicability at registration (-Platform/-Mode/-Requires)"
}

mode == "skip-constructs" && FNR == 1 {
  excluded = (FILENAME ~ /(^|\/)step-runner\.(sh|ps1)$/ ||
              FILENAME ~ /(^|\/)repository-policy\.awk$/ ||
              FILENAME ~ /(^|\/)1[123]-repo-policy-(grep|pattern|data)\.(sh|ps1)$/)
}
mode == "skip-constructs" && !excluded {
  if ($0 ~ /(^|[^A-Za-z0-9_])skip_step([^A-Za-z0-9_]|$)/) report_skip_construct("skip_step")
  if ($0 ~ /Skip-Step/) report_skip_construct("Skip-Step")
  if ($0 ~ /Invoke-SkippedStep/) report_skip_construct("Invoke-SkippedStep")
  if ($0 ~ /--skip-steps/) report_skip_construct("--skip-steps")
  if ($0 ~ /-SkipStep/) report_skip_construct("-SkipStep")
  if ($0 ~ /(^|[^A-Za-z0-9_])return[ \t]+2([^0-9]|$)/) report_skip_construct("return 2")
  if ($0 ~ /(^|[^A-Za-z0-9_])SKIPPED([^A-Za-z0-9_]|$)/) report_skip_construct("SKIPPED")
  if ($0 ~ /-SkipMessage/) report_skip_construct("-SkipMessage")
  if ($0 ~ /(^|[^A-Za-z0-9_])assert_skip([^A-Za-z0-9_]|$)/) report_skip_construct("assert_skip")
  if ($0 ~ /(^|[^A-Za-z0-9_])TESTS_SKIPPED([^A-Za-z0-9_]|$)/) report_skip_construct("TESTS_SKIPPED")
}
