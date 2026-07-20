# Picard INI merge orchestration.
# Tokens: __AWK_PATH__, __PICARD_OVERRIDE_COMMANDS__

_upsert_ini_key() {
  _conf="$1"
  _section="$2"
  _key="$3"
  _value="$4"

  _conf_dir="$(dirname "$_conf")"
  mkdir -p "$_conf_dir"

  if [ -f "$_conf" ]; then
    _tmp="$(mktemp "$_conf.XXXXXX")"
    # Pass value through ENVIRON instead of -v to prevent AWK from
    # interpreting escape sequences (e.g. \0, \b, \x41) that appear
    # literally in Picard's @Variant(…) serialized Qt values.
    # AWK -v treats the argument as a string constant and processes
    # backslash escapes; ENVIRON reads the raw bytes unchanged.
    _UPSERT_VALUE="$_value" "__AWK_PATH__" -v section="$_section" -v key="$_key" '
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
    ' "$_conf" > "$_tmp"
    mv "$_tmp" "$_conf"
  else
    cat > "$_conf" <<EOF
[$_section]
$_key=$_value
EOF
  fi
}

_apply_picard_defaults_from_file() {
  _defaults="$1"
  _conf="$2"

  "__AWK_PATH__" '
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
  ' "$_defaults" | while IFS=$'\t' read -r _section _key _value; do
    _upsert_ini_key "$_conf" "$_section" "$_key" "$_value"
  done
}

_picard_conf="${XDG_CONFIG_HOME:-$HOME/.config}/MusicBrainz/Picard.ini"
_picard_defaults_file="$(mktemp "${TMPDIR:-/tmp}/picard-defaults.XXXXXX.ini")"
trap 'rm -f "$_picard_defaults_file"' EXIT
printf '%s' __PICARD_DEFAULTS_INI__ > "$_picard_defaults_file"

_apply_picard_defaults_from_file "$_picard_defaults_file" "$_picard_conf"

__PICARD_OVERRIDE_COMMANDS__
