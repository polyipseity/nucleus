"""Resolve steamcmd_install_path from a merged RimSort settings JSON file."""

import json
import sys

d = json.load(open(sys.argv[1]))
inst = d.get("instances", {}).get("Default", {})
print(inst.get("steamcmd_install_path", ""))
