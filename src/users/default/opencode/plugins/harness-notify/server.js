/**
 * OpenCode v2 server plugin that routes session lifecycle events to the shared
 * harness notification entry point (`nucleus-utils harness send-notification`),
 * answers tool-permission requests from a messaging channel, and delivers prompts
 * queued with `/harness send opencode <text>`.
 *
 * v2 contract (server side, evidence in
 * .superpowers/sdd/plan/reports/opencode-v2-contract.md and throwaway probes of
 * @opencode/plugin@2.3.0 / @opencode/client promise types):
 *   - events: `context.event.subscribe()` yields v2 bus events, including
 *     `session.idle` (data.sessionID), `permission.asked` (data.id, data.sessionID,
 *     data.action), `session.execution.failed` and `session.execution.interrupted`
 *     (data.sessionID). v1 `session.error` is not present in the v2 event union;
 *     execution failures/interruption are the failure signals.
 *   - permissions: `context.permission.reply({ sessionID, requestID, decision })`
 *     with decision `once` | `always` | `reject`.
 *   - prompt injection: `context.session.prompt({ sessionID, text })`.
 *
 * Side split: all surviving behavior (detached external notification, permission
 * bridge reply, queued prompt injection) is reachable from the server plugin.
 * `attention.notify` is TUI-only in v2 typings, but in-app attention is not part
 * of the surviving contract; external notification remains the detached
 * `nucleus-utils harness send-notification` child. This plugin is therefore server-only.
 *
 * Only *when* to speak is decided here; channel selection and message formatting
 * belong to `nucleus-utils harness send-notification`. Every failure is discarded: a notification or a
 * bridge outage must never surface as an OpenCode error, and a request nobody
 * answered keeps OpenCode's own local prompt (the broker answers `ask` when the
 * bridge is disabled, unreachable, or unanswered).
 */

import { execFile, spawn } from "node:child_process";
import { readdirSync, readFileSync, unlinkSync } from "node:fs";
import { homedir } from "node:os";
import path from "node:path";
import { promisify } from "node:util";

const runFile = promisify(execFile);

const NOTIFY_COMMAND = "nucleus-utils";
const APPROVAL_COMMAND = "nucleus-utils";
// The approval sources race with finite bounds by default (300 s for hermes,
// 600 s for prompt), so this is the ceiling for the whole wait rather than a
// limit under the gate: 3600 s matches the hook budget the shared hook files
// declare, and the harness falls back to its own prompt when it expires.
const APPROVAL_TIMEOUT_MS = 3_600_000;

/**
 * Nucleus USER root, mirroring derive_nucleus_user_root in
 * src/scripts/lib/lib.sh. OpenCode is provisioned on every host, so the path
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
 * queue is empty. The file is deleted before its text is returned: the queue is
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
 * @param {string} event Notification event name understood by harness send-notification.
 * @param {string} text  Notification body.
 */
function notify(event, text) {
  const child = spawn(NOTIFY_COMMAND, ["harness", "send-notification", "opencode", event, text], {
    detached: true,
    stdio: "ignore",
  });
  // A missing command emits 'error' on the child; without a listener Node/Bun
  // would throw it into the session.
  child.on("error", () => {});
  child.unref();
}

const DECISION_CONTRACT_DECISIONS = new Set(["allow", "deny", "ask"]);
const DECISION_CONTRACT_SOURCES = new Set([
  "prompt",
  "hermes",
  "all-timeouts",
  "resolver-error",
  "none",
]);
const DECISION_CONTRACT_TIMED_OUT_SOURCES = new Set(["hermes", "prompt"]);
const DECISION_CONTRACT_KEYS = [
  "version",
  "decision",
  "reason",
  "source",
  "timeouts",
  "timedOutSources",
];

/** The typed decision document, or null when stdout carries no usable decision. */
function parseDecisionDocument(stdout) {
  try {
    const doc = JSON.parse(stdout.trim().split("\n").pop()?.trim() ?? "");
    if (typeof doc !== "object" || doc === null || Array.isArray(doc)) return null;
    // The schema sets additionalProperties: false, so an extra top-level field
    // makes the whole document unusable.
    if (Object.keys(doc).length !== DECISION_CONTRACT_KEYS.length) return null;
    if (DECISION_CONTRACT_KEYS.some((key) => !Object.prototype.hasOwnProperty.call(doc, key))) return null;
    if (doc.version !== 1) return null;
    if (!DECISION_CONTRACT_DECISIONS.has(doc.decision)) return null;
    if (typeof doc.reason !== "string") return null;
    if (!DECISION_CONTRACT_SOURCES.has(doc.source)) return null;
    if (typeof doc.timeouts !== "object" || doc.timeouts === null || Array.isArray(doc.timeouts)) return null;
    if (doc.timeouts.hermes !== 300 || doc.timeouts.prompt !== 600) return null;
    if (!Array.isArray(doc.timedOutSources)) return null;
    if (!doc.timedOutSources.every((name) => DECISION_CONTRACT_TIMED_OUT_SOURCES.has(name))) return null;
    return { decision: doc.decision, reason: doc.reason };
  } catch {
    return null;
  }
}

/** Event payload ids are optional in every field OpenCode has exposed so far. */
function asId(value) {
  return typeof value === "string" && value !== "" ? value : null;
}

/**
 * Ask the bridge for a decision on one permission request. Only allow and deny
 * are applied; `ask` means "nobody answered", which must leave OpenCode's own
 * local prompt in place. A deny carries the resolver's reason so the approval
 * notification can state why the call was rejected.
 */
async function decideRemotely(tool, summary) {
  try {
    const { stdout } = await runFile(APPROVAL_COMMAND, ["harness", "request-approval", "opencode", tool, summary], {
      timeout: APPROVAL_TIMEOUT_MS,
    });
    const parsed = parseDecisionDocument(stdout);
    if (parsed !== null && parsed.decision !== "ask") return parsed;
  } catch {
    // Broker missing, wedged or killed: the local prompt decides.
  }
  return { decision: "ask", reason: "" };
}

/**
 * Apply a decision through the v2 permission API. v2 reply takes
 * { sessionID, requestID, decision: "once"|"always"|"reject" }.
 */
async function replyToPermission(context, sessionID, requestID, decision) {
  const reply = context?.permission?.reply;
  if (typeof reply !== "function") return;
  await reply({
    sessionID,
    requestID,
    decision: decision === "allow" ? "once" : "reject",
  });
}

/** Inject a queued prompt as a new user turn via v2 session.prompt. */
async function injectPrompt(context, sessionID, text) {
  const prompt = context?.session?.prompt;
  if (typeof prompt !== "function") return;
  await prompt({ sessionID, text });
}

/** Project label for the notification body. */
function projectLabel(directory) {
  if (typeof directory === "string" && directory !== "") {
    return path.basename(directory);
  }
  return "opencode";
}

/**
 * Best-effort sandbox-state recording so a transition seen by one agent is
 * reported to the next. Failures are discarded: recording must never affect
 * notification, permission, or prompt-injection behavior.
 */
function recordSandboxContext(sessionID) {
  try {
    const args = ["harness", "report-sandbox", "opencode", "--format", "check"];
    if (typeof sessionID === "string" && sessionID !== "") {
      args.push("--session-id", sessionID);
    }
    const child = spawn(NOTIFY_COMMAND, args, {
      stdio: "ignore",
      detached: false,
    });
    child.on("error", () => {
      // Recording is best-effort.
    });
  } catch {
    // Recording is best-effort.
  }
}

/**
 * Handle one v2 bus event. All failures are discarded: the bridge is best-effort
 * and must never turn a session event into a failure.
 */
async function handleEvent(event, context, project) {
  try {
    const type = event?.type;
    const data = event?.data ?? {};
    recordSandboxContext(asId(data.sessionID));

    if (type === "session.idle") {
      notify("done", `${project} — session idle`);
      const sessionID = asId(data.sessionID);
      const text = takeQueuedPrompt();
      if (text !== null && sessionID !== null) {
        await injectPrompt(context, sessionID, text);
      }
      return;
    }

    if (type === "permission.asked") {
      const detail = typeof data.message === "string" && data.message !== ""
        ? ` — ${data.message}`
        : "";
      const sessionID = asId(data.sessionID);
      const requestID = asId(data.id);
      if (sessionID === null || requestID === null) {
        // Without both ids the answer could not be applied, so the request is
        // only announced; OpenCode keeps its own prompt.
        notify("approval", `${project} — permission requested${detail}`);
        return;
      }
      const tool = asId(data.action) ?? "permission";
      const answer = await decideRemotely(tool, `${project}${detail}`);
      if (answer.decision === "ask") {
        notify(
          "approval",
          `${project} — permission requested${detail} (no remote answer)`,
        );
        return;
      }
      if (answer.decision === "deny") {
        notify("approval", `${project} — permission denied: ${answer.reason}`);
      }
      await replyToPermission(context, sessionID, requestID, answer.decision);
      return;
    }

    if (type === "session.execution.failed" || type === "session.execution.interrupted") {
      notify("error", `${project} — session error`);
    }
  } catch {
    // Intentionally discarded (see module header).
  }
}

export default {
  id: "harness-notify",
  async setup(context) {
    const project = projectLabel(context?.location?.directory ?? context?.app?.name);
    const abort = new AbortController();

    const loop = (async () => {
      try {
        const subscribe = context?.event?.subscribe;
        if (typeof subscribe !== "function") return;
        for await (const event of subscribe()) {
          if (abort.signal.aborted) break;
          await handleEvent(event, context, project);
        }
      } catch {
        // Subscription ended or unavailable: nothing to retry here, and the
        // harness must not see a failure.
      }
    })();

    return async () => {
      abort.abort();
      try {
        await loop;
      } catch {
        // Teardown is best-effort.
      }
    };
  },
};
