// Trust directories in VS Code's workspace trust database (state.vscdb).
// Called from Set-VSCodeWorkspaceTrust.ps1; the MJS script is written to a
// temp file and executed via bun.
//
// Reads shared trust paths from trust-paths.json and writes trust entries
// to each VS Code channel's state.vscdb.
//
// argv[2] = absolute path to trust-paths.json; argv[3+] = absolute paths to state.vscdb files.

import { Database } from "bun:sqlite";
import { readFileSync, existsSync } from "node:fs";
import { join } from "node:path";

const TRUST_KEY = "content.trust.model.key";
const trustPathsFile = process.argv[2];
const dbPaths = process.argv.slice(3);

// Read shared trust paths.
if (!existsSync(trustPathsFile)) {
  console.error("vscode-workspace-trust: warning:", trustPathsFile, "not found");
  process.exit(0);
}

let config;
try {
  config = JSON.parse(readFileSync(trustPathsFile, "utf-8"));
} catch (e) {
  console.error("vscode-workspace-trust: warning: could not read", trustPathsFile, "-", e.message);
  process.exit(0);
}

const homeDir = process.env.HOME || process.env.USERPROFILE || "";

// Expand ~ and convert to VS Code URI format.
function toUriPath(raw) {
  const expanded = raw.startsWith("~/") ? join(homeDir, raw.slice(2)) : raw;
  if (!existsSync(expanded)) {
    console.error("vscode-workspace-trust: skipping", expanded, "(not a directory)");
    return null;
  }
  // VS Code encodes file URIs with a lowercase drive letter, a colon, and
  // forward slashes, preceded by a leading slash:
  //   C:\Users\user\dev  →  /c:/Users/user/dev
  const driveLetter = expanded.substring(0, 1).toLowerCase();
  const pathRest = expanded.substring(2).replace(/\\/g, "/");
  return `/${driveLetter}:${pathRest}`;
}

const uriPaths = (config.paths || []).map(toUriPath).filter(Boolean);

if (uriPaths.length === 0) {
  process.exit(0);
}

for (const dbPath of dbPaths) {
  if (!existsSync(dbPath)) continue;
  let db;
  try {
    db = new Database(dbPath, { readwrite: true });
    const row = db
      .query("SELECT value FROM ItemTable WHERE key = ?")
      .get(TRUST_KEY);
    let data;
    let entries;
    if (row) {
      data = JSON.parse(row.value);
      entries = data.uriTrustInfo ?? [];
    } else {
      data = {};
      entries = [];
    }

    let added = false;
    for (const uriPath of uriPaths) {
      const alreadyTrusted = entries.some(
        (e) => e.uri?.path === uriPath && e.uri?.scheme === "file",
      );
      if (!alreadyTrusted) {
        entries.push({
          uri: { $mid: 1, path: uriPath, scheme: "file" },
          trusted: true,
        });
        added = true;
      }
    }

    if (added) {
      data.uriTrustInfo = entries;
      db.run("INSERT OR REPLACE INTO ItemTable (key, value) VALUES (?, ?)", [
        TRUST_KEY,
        JSON.stringify(data),
      ]);
      console.error(
        "vscode-workspace-trust: trusted",
        uriPaths.length,
        "path(s) in",
        dbPath,
      );
    }
  } catch (e) {
    console.error(
      "vscode-workspace-trust: warning:",
      dbPath,
      "-",
      e.message,
    );
  } finally {
    if (db) db.close();
  }
}
