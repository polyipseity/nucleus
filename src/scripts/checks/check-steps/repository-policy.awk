# repository-policy.awk — check step 14 pattern scans.
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
# return 2, SKIPPED, -SkipMessage) under src/scripts/, scripts/ or tests/. The
# two runners document the declared-applicability contract, and this file plus
# the two gate steps carry the pattern list, so all of them are excluded here.
# The word "skip" in prose stays legal; only the named constructs match.

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
    if ($0 ~ /`e/)
      print FILENAME ":" FNR ": backtick-e escape literal (use PSStyle helpers)"
  }
}

function report_skip_construct(construct) {
  print FILENAME ":" FNR ": removed skip mechanism '" construct "'; declare applicability at registration (-Platform/-Mode/-Requires)"
}

mode == "skip-constructs" && FNR == 1 {
  excluded = (FILENAME ~ /(^|\/)step-runner\.(sh|ps1)$/ ||
              FILENAME ~ /(^|\/)repository-policy\.awk$/ ||
              FILENAME ~ /(^|\/)14-repository-policy\.(sh|ps1)$/)
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
}
