#!/usr/bin/env bash
# QtPass INI merge shell helpers.

set -euo pipefail


_mqi_awk_bin="$1"
_mqi_darwin_commands="$2"
_mqi_linux_primary_commands="$3"
_mqi_linux_secondary_commands="$4"

_escape_qsettings_ini_string() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e ':join' -e 'N' -e '$!b join' -e 's/\n/\\n/g'
}

_update_qtpass_ini_value() {
  _conf="$1"
  _key="$2"
  _value="$3"
  _conf_dir="$(dirname "$_conf")"
  mkdir -p "$_conf_dir"

  if [ -f "$_conf" ]; then
    _tmp="$(mktemp "$_conf.XXXXXX")"
    "$_mqi_awk_bin" -v key="$_key" -v value="$_value" '
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
    ' "$_conf" > "$_tmp"
    mv "$_tmp" "$_conf"
  else
    cat > "$_conf" <<EOF
[General]
$_key=$_value
EOF
  fi
}

case "$(uname -s)" in
  Darwin)
    eval "$_mqi_darwin_commands"
    ;;
  Linux)
    # QtPass upstream commonly resolves to ~/.config/IJHack/QtPass.conf.
    _primary_conf="$HOME/.config/IJHack/QtPass.conf"
    # Some builds may resolve via organization-domain pathing.
    _secondary_conf="$HOME/.config/com.ijhack/QtPass.conf"

    eval "$_mqi_linux_primary_commands"
    if [ -f "$_secondary_conf" ]; then
      eval "$_mqi_linux_secondary_commands"
    fi
    ;;
esac
