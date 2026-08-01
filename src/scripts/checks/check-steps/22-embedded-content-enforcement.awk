# 22-embedded-content-enforcement.awk — heredoc size detector for check step 22.
# Flags heredocs with more than 30 content lines (embedded-content policy).
FNR == 1 { in_heredoc = 0 }
!in_heredoc && match($0, /<<-?[ \t]*["\047\\]?[A-Za-z_][A-Za-z0-9_]*/) {
  op = substr($0, RSTART, RLENGTH)
  tag = op
  sub(/^<<-?[ \t]*["\047\\]?/, "", tag)
  dash = (substr(op, 3, 1) == "-")
  in_heredoc = 1
  start_line = FNR
  body = 0
  next
}
in_heredoc {
  if (dash && $0 ~ "^[ \t]*" tag "[ \t]*$") { in_heredoc = 0 }
  else if (!dash && $0 ~ "^" tag "[ \t]*$") { in_heredoc = 0 }
  else { body++; next }
  if (body > 30) print FILENAME ":" start_line ": heredoc " tag " has " body " content lines (limit 30)"
}
