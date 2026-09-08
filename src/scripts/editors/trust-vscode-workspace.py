#!/usr/bin/env python3
"""Trust directories in VS Code's workspace trust database (state.vscdb).

Reads the shared trust path list from trust-paths.json and inserts trust
entries for each path into VS Code's per-channel globalStorage SQLite
database. Handles both stable and insiders channels. Non-fatal on
locked/absent databases.
"""

import json
import os
import sqlite3
import sys

HOME = os.environ.get("HOME", "")

# Locate trust-paths.json relative to this script.
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
TRUST_PATHS_FILE = os.path.join(SCRIPT_DIR, "trust-paths.json")

if not os.path.isfile(TRUST_PATHS_FILE):
    print("vscode-trust: warning:", TRUST_PATHS_FILE, "not found", file=sys.stderr)
    sys.exit(0)

with open(TRUST_PATHS_FILE, encoding="utf-8") as f:
    config = json.load(f)

paths_to_trust = []
for raw in config.get("paths", []):
    expanded = os.path.expanduser(raw)
    if os.path.isdir(expanded):
        paths_to_trust.append(expanded)
    else:
        print("vscode-trust: skipping", expanded, "(not a directory)", file=sys.stderr)

if not paths_to_trust:
    sys.exit(0)

# Locate the state.vscdb for both stable and insiders channels.
if sys.platform == "darwin":
    app_support = os.path.join(HOME, "Library", "Application Support")
    db_paths = [
        os.path.join(app_support, "Code", "User", "globalStorage", "state.vscdb"),
        os.path.join(
            app_support, "Code - Insiders", "User", "globalStorage", "state.vscdb"
        ),
    ]
else:
    config_home = os.environ.get("XDG_CONFIG_HOME", os.path.join(HOME, ".config"))
    db_paths = [
        os.path.join(config_home, "Code", "User", "globalStorage", "state.vscdb"),
        os.path.join(
            config_home, "Code - Insiders", "User", "globalStorage", "state.vscdb"
        ),
    ]

TRUST_KEY = "content.trust.model.key"

for db_path in db_paths:
    if not os.path.isfile(db_path):
        continue
    try:
        conn = sqlite3.connect(db_path, timeout=5)
        try:
            cur = conn.cursor()
            cur.execute("SELECT value FROM ItemTable WHERE key = ?", (TRUST_KEY,))
            row = cur.fetchone()
            if row:
                data = json.loads(row[0])
                entries = data.get("uriTrustInfo", [])
            else:
                data = {}
                entries = []

            added = False
            for path in paths_to_trust:
                already_trusted = any(
                    e.get("uri", {}).get("path") == path
                    and e.get("uri", {}).get("scheme") == "file"
                    for e in entries
                )
                if not already_trusted:
                    entries.append(
                        {
                            "uri": {"$mid": 1, "path": path, "scheme": "file"},
                            "trusted": True,
                        }
                    )
                    added = True

            if added:
                data["uriTrustInfo"] = entries
                new_value = json.dumps(data, separators=(",", ":"))
                cur.execute(
                    "INSERT OR REPLACE INTO ItemTable (key, value) VALUES (?, ?)",
                    (TRUST_KEY, new_value),
                )
                conn.commit()
                print(
                    "vscode-trust: trusted",
                    len(paths_to_trust),
                    "path(s) in",
                    db_path,
                    file=sys.stderr,
                )
        finally:
            conn.close()
    except (sqlite3.Error, OSError, ValueError) as e:
        print("vscode-trust: warning:", db_path, "-", e, file=sys.stderr)
