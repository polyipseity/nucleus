#!/usr/bin/env python3
"""Trust ~/dev directory in VS Code's workspace trust database (state.vscdb).

Reads VS Code's per-channel globalStorage SQLite database and inserts a trust
entry for ~/dev. Handles both stable and insiders channels. Non-fatal on
locked/absent databases.
"""

import json
import os
import sqlite3
import sys

HOME = os.environ.get("HOME", "")
dev_path = os.path.join(HOME, "dev")

# Only trust the dev directory when it actually exists on this machine.
# Exits immediately when ~/dev is absent (edge case: first-run race before
# provisionDevDirectory completes; resolved on the next apply).
if not os.path.isdir(dev_path):
    sys.exit(0)

trust_entry = {
    "uri": {"$mid": 1, "path": dev_path, "scheme": "file"},
    "trusted": True,
}

# Locate the state.vscdb for both stable and insiders channels.
# The per-channel globalStorage directory is the authoritative location
# for VS Code APPLICATION-scope storage regardless of installation backend.
if sys.platform == "darwin":
    app_support = os.path.join(HOME, "Library", "Application Support")
    db_paths = [
        os.path.join(app_support, "Code", "User", "globalStorage", "state.vscdb"),
        os.path.join(app_support, "Code - Insiders", "User", "globalStorage", "state.vscdb"),
    ]
else:
    config_home = os.environ.get("XDG_CONFIG_HOME", os.path.join(HOME, ".config"))
    db_paths = [
        os.path.join(config_home, "Code", "User", "globalStorage", "state.vscdb"),
        os.path.join(config_home, "Code - Insiders", "User", "globalStorage", "state.vscdb"),
    ]

TRUST_KEY = "content.trust.model.key"

for db_path in db_paths:
    if not os.path.isfile(db_path):
        continue
    try:
        # timeout=5 waits up to 5 s for a SQLite lock; if VS Code holds
        # the lock longer the OperationalError is caught below (non-fatal).
        conn = sqlite3.connect(db_path, timeout=5)
        try:
            cur = conn.cursor()
            cur.execute("SELECT value FROM ItemTable WHERE key = ?", (TRUST_KEY,))
            row = cur.fetchone()
            if row:
                data = json.loads(row[0])
                entries = data.get("uriTrustInfo", [])
                already_trusted = any(
                    e.get("uri", {}).get("path") == dev_path
                    and e.get("uri", {}).get("scheme") == "file"
                    for e in entries
                )
                if already_trusted:
                    continue
                entries.append(trust_entry)
                data["uriTrustInfo"] = entries
            else:
                data = {"uriTrustInfo": [trust_entry]}
            new_value = json.dumps(data, separators=(",", ":"))
            cur.execute(
                "INSERT OR REPLACE INTO ItemTable (key, value) VALUES (?, ?)",
                (TRUST_KEY, new_value),
            )
            conn.commit()
            print("vscode-trust: trusted", dev_path, "in", db_path, file=sys.stderr)
        finally:
            conn.close()
    except Exception as e:
        # Non-fatal: DB may be locked by a running VS Code instance, or
        # absent on a fresh install before VS Code has been launched once.
        print("vscode-trust: warning:", db_path, "-", e, file=sys.stderr)
