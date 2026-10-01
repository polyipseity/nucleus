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

# Text-hygiene mode (-v mode=em-dash): fails on U+2014 in repo-owned prose,
# which the prose-style rule in documentation.instructions.md bans. Only prose
# is scanned: comment lines in code plus every line of a tracked .md file. An
# em dash inside a quoted string, a here-string, a printf format or a regex is
# program output or data, so it stays legal. The .awk file itself is not in the
# scanned extension set, which is what keeps the literal below out of findings.
#
# WHY octal and not \x or \u: awk string escapes are octal in POSIX, \x is a gawk
# extension, and \u expands to literal text under bash 3.2. The dash is compared
# with index() and string equality so no regex has to carry the byte sequence,
# which is where an escape would silently stop matching.

BEGIN { em_dash = "\342\200\224" }

function em_dash_path_excluded(path) {
  # WHY humanizer: the skill documents the em dash by printing sentences that
  # contain one, so its examples cannot be clean without losing their point.
  return path ~ /(^|\/)(vendor|node_modules)\// || path ~ /(^|\/)skills\/humanizer\//
}

# A table cell holding only the em dash is a placeholder for "not applicable",
# which reads as content rather than punctuation. Split on the pipe and compare
# the trimmed cells, which is what the PowerShell twin does, so the two agree.
# An em dash inside a markdown inline code span names a literal value, the way a
# quoted string does in code. Raycast's "Auto-switch Input Source" menu really
# does offer an item spelled with a dash, and the instruction has to say so.
# WHY markdown only: a code span is markdown's literal-value syntax.
function em_dash_strip_code_spans(line,   out, _i, _n, parts) {
  _n = split(line, parts, /`/)
  out = ""
  for (_i = 1; _i <= _n; _i++) {
    if (_i % 2 == 1) out = out parts[_i]
  }
  return out
}

function em_dash_placeholder_cell(line,   parts, _i, _n) {
  _n = split(line, parts, /\|/)
  for (_i = 1; _i <= _n; _i++) {
    gsub(/^[ \t]+|[ \t]+$/, "", parts[_i])
    if (parts[_i] == em_dash) return 1
  }
  return 0
}

mode == "em-dash" && FNR == 1 {
  in_help = 0
  in_fence = 0
  em_dash_md = (FILENAME ~ /\.md$/)
  em_dash_ps = (FILENAME ~ /\.(ps1|psm1)$/)
}
mode == "em-dash" {
  if (em_dash_md && $0 ~ /^[ \t]*(```|~~~)/) in_fence = !in_fence
  # A one-line help block opens and closes on the same line, so its text is
  # prose on the opening line too.
  if (em_dash_md) em_dash_scan_line = em_dash_strip_code_spans($0)
  else em_dash_scan_line = $0
  if (!em_dash_path_excluded(FILENAME) && !in_fence && !em_dash_placeholder_cell($0) &&
      index(em_dash_scan_line, em_dash) > 0) {
    if (em_dash_md || in_help || $0 ~ /^[ \t]*#/ || $0 ~ /<#/) {
      print FILENAME ":" FNR ": em dash in prose (use a comma, a colon, or two sentences)"
    }
  }
  if (em_dash_ps) {
    if (!in_help && $0 ~ /<#/) {
      in_help = ($0 ~ /#>/ ? 0 : 1)
    } else if (in_help && $0 ~ /#>/) {
      in_help = 0
    }
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
