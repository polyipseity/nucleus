#!/usr/bin/env bash
# Cap battery charging so a mostly-docked Linux machine does not sit at 100 %.
#
# Positional arguments:
#   $1 — power_supply class root (default: /sys/class/power_supply)
#
# Exit conditions: 0 when every battery that supports a charge limit carries the
# managed values (or no battery supports one), non-zero when a required write or
# read-back fails.
#
# WHY: capping charge is the most effective lever on battery wear, and Linux
#   exposes it as a plain sysfs attribute (`charge_control_end_threshold`), so no
#   vendor daemon has to be installed and trusted.  Hardware without the
#   attribute cannot cap charge at all; that is reported, not failed.
#
# WHY a resume level below the ceiling: `charge_control_start_threshold` is
#   written only where the attribute exists, and it sits below the 80 % ceiling
#   so the pack is not re-charged after every 1 % discharge.

set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=../../../scripts/lib/lib.sh
. "$SCRIPT_DIR/../../../scripts/lib/lib.sh"

charge_limit_end=80
charge_limit_start=75

power_supply_root="${1:-/sys/class/power_supply}"

# write_threshold <path> <value> — write the value, then read it back.
# WHY the read-back: firmware that rejects or clamps the request keeps the old
#   value, and reporting that silent no-op as converged would leave the pack
#   charging to 100 % while activation claims the limit is in place.
write_threshold() {
  local path="$1" value="$2" current
  if ! printf '%s\n' "$value" >"$path"; then
    die -l power "failed to write '$value' to $path."
  fi
  if ! IFS= read -r current <"$path"; then
    die -l power "failed to read back $path after writing '$value'."
  fi
  if [ "$current" != "$value" ]; then
    die -l power "$path kept '$current' instead of '$value'."
  fi
}

if [ ! -d "$power_supply_root" ]; then
  die -l power "power supply root '$power_supply_root' does not exist."
fi

battery_count=0
for battery_dir in "$power_supply_root"/BAT*; do
  if [ ! -d "$battery_dir" ]; then
    continue
  fi
  end_path="$battery_dir/charge_control_end_threshold"
  if [ ! -e "$end_path" ]; then
    continue
  fi
  battery_count=$((battery_count + 1))
  # WHY this order: the ceiling is written before the resume level, because the
  #   kernel rejects a resume level that sits above the current ceiling.
  write_threshold "$end_path" "$charge_limit_end"
  start_path="$battery_dir/charge_control_start_threshold"
  if [ -e "$start_path" ]; then
    write_threshold "$start_path" "$charge_limit_start"
  fi
done

if [ "$battery_count" -eq 0 ]; then
  notice -l power "no battery exposes charge_control_end_threshold; the charge limit is not supported on this hardware."
fi
