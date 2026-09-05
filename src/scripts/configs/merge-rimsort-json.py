import json
import os
import sys
from pathlib import Path

config_path = Path(sys.argv[1])
managed = json.loads(sys.argv[2])

if config_path.exists():
    raw = config_path.read_text(encoding="utf-8")
    existing = json.loads(raw) if raw.strip() else {}
else:
    existing = {}

if not isinstance(existing, dict):
    print(f"rimsort: expected top-level JSON object in {config_path}", file=sys.stderr)
    sys.exit(1)

# Ensure the instances and Default instance keys exist so managed keys
# can be merged into the correct nesting level.
instances = existing.setdefault("instances", {})
default_instance = instances.setdefault("Default", {})

managed_instances = managed.get("instances", {})
managed_default = managed_instances.get("Default", {})

if not isinstance(managed_default, dict):
    print("rimsort: managed settings must contain instances.Default object", file=sys.stderr)
    sys.exit(1)

# Merge top-level managed keys (e.g. current_instance) into the
# existing config. The "instances" key is handled separately below.
for key, value in managed.items():
    if key != "instances":
        existing[key] = value

# Deep-merge managed keys into the Default instance. Managed keys
# overwrite any existing values; unmanaged keys (theme, sorting,
# window state, SteamCMD paths) are preserved unchanged.
default_instance.update(managed_default)

# Expand ~ to home directory in string values. RimSort does not
# call expanduser() on steamcmd_install_path, so tilde-prefixed
# paths cause a PermissionError crash at startup.
for key in default_instance:
    value = default_instance[key]
    if isinstance(value, str):
        default_instance[key] = os.path.expanduser(value)

config_path.parent.mkdir(parents=True, exist_ok=True)
config_path.write_text(
    json.dumps(existing, indent=4, sort_keys=True) + "\n",
    encoding="utf-8",
)
