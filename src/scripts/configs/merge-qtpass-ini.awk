# QtPass INI value update — upserts a key=value pair under [General].
# Parameters (passed via -v): key, value
BEGIN { in_general = 0; wrote = 0 }
{
  if ($0 ~ /^\[General\]$/) {
    if (in_general && wrote == 0) {
      print key "=" value
      wrote = 1
    }
    in_general = 1
    print
    next
  }

  if ($0 ~ /^\[/ && $0 !~ /^\[General\]$/) {
    if (in_general && wrote == 0) {
      print key "=" value
      wrote = 1
    }
    in_general = 0
    print
    next
  }

  if (in_general && $0 ~ ("^" key "=")) {
    if (wrote == 0) {
      print key "=" value
      wrote = 1
    }
    next
  }

  print
}
END {
  if (wrote == 0) {
    if (in_general == 0) {
      print "[General]"
    }
    print key "=" value
  }
}
