/**
 * OpenCode plugin that routes session lifecycle events to the shared harness
 * notification entry point (`harness-notify`, deployed to ~/.local/bin), answers
 * tool-permission requests from a messaging channel, and delivers prompts queued
 * with `/harness send opencode <text>`.
 *
 * Events used (OpenCode's plugin `event` hook carries the server event bus):
 *   - `session.idle`     — the session stopped working: the turn is done, and
 *                          the moment a queued remote prompt is delivered.
 *   - `permission.asked` — OpenCode is blocked waiting for a tool permission
 *                          decision: the broker asks the user, and the answer is
 *                          applied through the SDK.
 *   - `session.error`    — the turn failed.
 *
 * Only *when* to speak is decided here; channel selection and message
 * formatting belong to `harness-notify`.  Every failure is discarded: a
 * notification or a bridge outage must never surface as an OpenCode error, and a
 * request nobody answered keeps OpenCode's own local prompt (the broker answers
 * `ask` when the bridge is disabled, unreachable, or unanswered).
 *
 * The notification child is detached so a slow or wedged notification can never
 * delay the session.
 */

import { execFile, spawn } from "node:child_process";
import { readdirSync, readFileSync, unlinkSync } from "node:fs";
import { homedir } from "node:os";
import path from "node:path";
import { promisify } from "node:util";

const runFile = promisify(execFile);

const NOTIFY_COMMAND = "harness-notify";
const APPROVAL_COMMAND = "harness-approval";
// Must exceed harness-approval's own wait (harness-approval.timeout-seconds,
// default 120) so the broker's timeout — not this one — produces `ask`.
const APPROVAL_TIMEOUT_MS = 240_000;

/**
 * Nucleus USER root, mirroring derive_nucleus_user_root in
 * src/scripts/lib/lib.sh.  OpenCode is provisioned on every host, so the path
 * cannot be platform-specific.
 */
function nucleusUserRoot() {
  if (process.platform === "darwin") {
    return path.join(homedir(), "Library", "Application Support", "nucleus");
  }
  if (process.platform === "win32") {
    const localAppData = process.env.LOCALAPPDATA;
    return localAppData
      ? path.join(localAppData, "nucleus")
      : path.join(homedir(), "AppData", "Local", "nucleus");
  }
  return path.join(homedir(), ".local", "share", "nucleus");
}

/**
 * Consume one prompt queued by `/harness send opencode <text>`, or null when the
 * queue is empty.  The file is deleted before its text is returned: the queue is
 * the only loop guard this path has, so a prompt must never be delivered twice.
 */
function takeQueuedPrompt() {
  const dir = path.join(
    nucleusUserRoot(),
    "state",
    "harness-bridge",
    "commands",
    "opencode",
  );

  let names;
  try {
    names = readdirSync(dir).filter((name) => name.endsWith(".json"));
  } catch {
    // No queue directory yet: the ordinary state before the first /harness send.
    return null;
  }

  // The bridge names each entry "<epoch>-<id>.json", so the lexicographic
  // maximum is the most recently queued prompt.
  let newest = "";
  for (const name of names) {
    if (name > newest) newest = name;
  }
  if (newest === "") return null;

  const file = path.join(dir, newest);
  let text = "";
  try {
    const queued = JSON.parse(readFileSync(file, "utf8"));
    if (typeof queued.text === "string") text = queued.text.trim();
  } catch {
    // An unreadable queue entry is discarded below rather than retried forever.
    text = "";
  }
  try {
    unlinkSync(file);
  } catch {
    // Still on disk, so injecting now would deliver it again on the next idle.
    return null;
  }
  return text === "" ? null : text;
}

/**
 * Report one lifecycle event. Failures are intentionally discarded: a
 * notification is best-effort and must not surface as an OpenCode error.
 *
 * @param event Notification event name understood by harness-notify.
 * @param text  Notification body.
 */
function notify(event, text) {
  const child = spawn(NOTIFY_COMMAND, ["opencode", event, text], {
    detached: true,
    stdio: "ignore",
  });
  // A missing command emits 'error' on the child; without a listener Node
  // would throw it into the session.
  child.on("error", () => {});
  child.unref();
}

/** Event payload ids are optional in every field OpenCode has exposed so far. */
function asId(value) {
  return typeof value === "string" && value !== "" ? value : null;
}

/**
 * Ask the bridge for a decision on one permission request.  Only allow and deny
 * are applied; `ask` means "nobody answered", which must leave OpenCode's own
 * local prompt in place.
 */
async function decideRemotely(tool, summary) {
  try {
    const { stdout } = await runFile(
      APPROVAL_COMMAND,
      ["opencode", tool, summary],
      { timeout: APPROVAL_TIMEOUT_MS },
    );
    const lines = stdout.trim().split("\n");
    const decision = lines[lines.length - 1]?.trim();
    return decision === "allow" || decision === "deny" ? decision : "ask";
  } catch {
    // Broker missing, wedged or killed: the local prompt decides.
    return "ask";
  }
}

/**
 * Apply a decision through the SDK.  The pinned OpenCode ships two permission
 * namespaces ("session.permission.reply" in its current API and
 * "permission.reply" in the older one), so the method is resolved by shape; a
 * version exposing neither keeps its own local prompt instead of throwing into
 * the session.
 */
async function replyToPermission(client, sessionID, requestID, decision) {
  const params = {
    path: { sessionID, requestID },
    body: { reply: decision === "allow" ? "once" : "reject" },
  };
  const sessionPermission = client?.session?.permission;
  if (typeof sessionPermission?.reply === "function") {
    await sessionPermission.reply(params);
    return;
  }
  if (typeof client?.permission?.reply === "function") {
    await client.permission.reply(params);
  }
}

/** Inject a queued prompt as a new user turn, if this SDK exposes prompt(). */
async function injectPrompt(client, sessionID, text) {
  const prompt = client?.session?.prompt;
  if (typeof prompt !== "function") return;
  await prompt({
    path: { id: sessionID },
    body: { parts: [{ type: "text", text }] },
  });
}

/** Project label for the notification body. */
function projectLabel(directory) {
  return directory ? path.basename(directory) : "opencode";
}

export const HarnessNotifyPlugin = async ({ directory, client }) => {
  const project = projectLabel(directory);

  return {
    event: async ({ event }) => {
      // Every branch below talks to the SDK or the bridge; an unexpected shape
      // must not become an unhandled rejection inside the session.
      try {
        const properties = event.properties ?? {};
        switch (event.type) {
          case "session.idle": {
            notify("done", `${project} — session idle`);
            const text = takeQueuedPrompt();
            const sessionID = asId(properties.sessionID);
            if (text !== null && sessionID !== null) {
              await injectPrompt(client, sessionID, text);
            }
            break;
          }
          case "permission.asked": {
            const title = properties.permission?.title;
            const detail =
              typeof title === "string" && title !== "" ? ` — ${title}` : "";
            const sessionID = asId(properties.sessionID ?? properties.session?.id);
            const requestID = asId(
              properties.permission?.id ?? properties.requestID,
            );
            if (sessionID === null || requestID === null) {
              // Without both ids the answer could not be applied, so the request
              // is only announced; OpenCode keeps its own prompt.
              notify("approval", `${project} — permission requested${detail}`);
              break;
            }
            const tool =
              asId(properties.permission?.type) ?? "permission";
            const decision = await decideRemotely(tool, `${project}${detail}`);
            if (decision === "ask") {
              notify(
                "approval",
                `${project} — permission requested${detail} (no remote answer)`,
              );
              break;
            }
            await replyToPermission(client, sessionID, requestID, decision);
            break;
          }
          case "session.error":
            notify("error", `${project} — session error`);
            break;
        }
      } catch {
        // Intentionally discarded (see module header): the bridge is best-effort
        // and must never turn a session event into a failure.
      }
    },
  };
};
