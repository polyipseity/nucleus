"""Resolve steamcmd_install_path from a merged RimSort settings JSON file."""

import json
import sys

with open(sys.argv[1]) as f:
    d = json.load(f)
inst = d.get("instances", {}).get("Default", {})
print(inst.get("steamcmd_install_path", ""))
