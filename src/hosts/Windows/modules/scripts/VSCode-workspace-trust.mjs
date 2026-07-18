// Trust a directory path in VS Code's workspace trust database (state.vscdb).
// Called from Set-VSCodeWorkspaceTrust.ps1; the MJS script is written to a
// temp file and executed via bun.
//
// argv[2] = uriPath to trust; argv[3+] = absolute paths to state.vscdb files.

import { Database } from "bun:sqlite";
import { existsSync } from "node:fs";

const TRUST_KEY = "content.trust.model.key";
const uriPath = process.argv[2];
const dbPaths = process.argv.slice(3);

for (const dbPath of dbPaths) {
  if (!existsSync(dbPath)) continue;
  let db;
  try {
    db = new Database(dbPath, { readwrite: true });
    const row = db
      .query("SELECT value FROM ItemTable WHERE key = ?")
      .get(TRUST_KEY);
    let data;
    if (row) {
      data = JSON.parse(row.value);
      const entries = data.uriTrustInfo ?? [];
      const alreadyTrusted = entries.some(
        (e) => e.uri?.path === uriPath && e.uri?.scheme === "file",
      );
      if (alreadyTrusted) {
        db.close();
        continue;
      }
      // Append the trust entry to the existing list rather than replacing
      // it so that any other paths the user has manually trusted are preserved.
      entries.push({
        uri: { $mid: 1, path: uriPath, scheme: "file" },
        trusted: true,
      });
      data.uriTrustInfo = entries;
    } else {
      data = {
        uriTrustInfo: [
          { uri: { $mid: 1, path: uriPath, scheme: "file" }, trusted: true },
        ],
      };
    }
    db.run("INSERT OR REPLACE INTO ItemTable (key, value) VALUES (?, ?)", [
      TRUST_KEY,
      JSON.stringify(data),
    ]);
    console.error(
      "vscode-workspace-trust: Set-VSCodeWorkspaceTrust: trusted",
      uriPath,
      "in",
      dbPath,
    );
  } catch (e) {
    // Non-fatal: DB may be locked by a running VS Code instance.
    console.error(
      "vscode-workspace-trust: Set-VSCodeWorkspaceTrust: warning:",
      dbPath,
      "-",
      e.message,
    );
  } finally {
    if (db) db.close();
  }
}
