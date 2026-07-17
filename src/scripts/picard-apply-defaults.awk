BEGIN { section = "" }

/^[[:space:]]*([;#]|$)/ { next }

/^\[[^]]+\][[:space:]]*$/ {
    section = $0
    sub(/^\[/, "", section)
    sub(/\][[:space:]]*$/, "", section)
    next
}

{
    if (section == "") {
      next
    }

    pos = index($0, "=")
    if (pos == 0) {
      next
    }

    key = substr($0, 1, pos - 1)
    value = substr($0, pos + 1)
    gsub(/^[[:space:]]+|[[:space:]]+$/, "", key)

    if (key != "") {
      print section "\t" key "\t" value
    }
}
