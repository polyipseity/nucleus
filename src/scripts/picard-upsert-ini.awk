function write_pair() {
    if (wrote == 0) {
      print key "=" value
      wrote = 1
    }
}
BEGIN {
    in_target = 0
    section_seen = 0
    value = ENVIRON["_UPSERT_VALUE"]
    wrote = 0
}
{
    if ($0 ~ /^\[/) {
      if (in_target) {
        write_pair()
        in_target = 0
      }
      if ($0 == "[" section "]") {
        section_seen = 1
        in_target = 1
      }
      print
      next
    }

    if (in_target && $0 ~ ("^" key "=")) {
      if (wrote == 0) {
        print key "=" value
        wrote = 1
      }
      next
    }

    print
}
END {
    if (section_seen == 0) {
      print "[" section "]"
    }
    if (wrote == 0) {
      print key "=" value
    }
}
