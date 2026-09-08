#!/usr/bin/env python3
"""Trust directories in pi coding agent's project trust database (trust.json).

Reads the shared trust path list from trust-paths.json and inserts trust
entries for each canonicalized path into ~/.pi/agent/trust.json.
Non-fatal on IO errors.
"""

import json
import os
import sys

HOME = os.environ.get("HOME", "")
if not HOME:
    print("pi-trust: warning: HOME not set", file=sys.stderr)
    sys.exit(0)

# Locate trust-paths.json relative to this script.
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
TRUST_PATHS_FILE = os.path.join(SCRIPT_DIR, "trust-paths.json")

if not os.path.isfile(TRUST_PATHS_FILE):
    print("pi-trust: warning:", TRUST_PATHS_FILE, "not found", file=sys.stderr)
    sys.exit(0)

with open(TRUST_PATHS_FILE, encoding="utf-8") as f:
    config = json.load(f)

paths_to_trust = []
for raw in config.get("paths", []):
    expanded = os.path.expanduser(raw)
    # Canonicalize via realpath to match pi's canonicalizePath (realpathSync).
    try:
        canonical = os.path.realpath(expanded)
    except OSError:
        canonical = expanded
    if os.path.isdir(canonical):
        paths_to_trust.append(canonical)
    else:
        print("pi-trust: skipping", canonical, "(not a directory)", file=sys.stderr)

if not paths_to_trust:
    sys.exit(0)

# Trust file location.
trust_dir = os.path.join(HOME, ".pi", "agent")
trust_path = os.path.join(trust_dir, "trust.json")

# Read existing trust data (create if absent).
trust_data = {}
if os.path.isfile(trust_path):
    try:
        with open(trust_path, encoding="utf-8") as f:
            trust_data = json.load(f)
    except (json.JSONDecodeError, OSError) as e:
        print("pi-trust: warning: could not read", trust_path, "-", e, file=sys.stderr)
        trust_data = {}

# Add entries.
added = False
for path in paths_to_trust:
    if trust_data.get(path) is not True:
        trust_data[path] = True
        added = True

if not added:
    sys.exit(0)

# Write back sorted JSON with 2-space indent and trailing newline.
try:
    os.makedirs(trust_dir, exist_ok=True)
    sorted_data = {k: v for k, v in sorted(trust_data.items()) if v is True or v is False}
    with open(trust_path, "w", encoding="utf-8") as f:
        json.dump(sorted_data, f, indent=2)
        f.write("\n")
    print(
        "pi-trust: trusted", len(paths_to_trust), "path(s) in", trust_path,
        file=sys.stderr,
    )
except OSError as e:
    print("pi-trust: warning:", trust_path, "-", e, file=sys.stderr)
