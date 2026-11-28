/**
 * Pi extension that routes risky tool calls through the shared remote-approval
 * broker (`request-approval`, deployed to ~/.local/bin).
 *
 * Only a conservative pattern list is gated. Prompting for every tool call would
 * make the agent unusable, and pi already has its own permission model for the
 * rest; the patterns here are the commands a person would want to veto from a
 * phone: privilege escalation, pushes, piping to a shell, recursive chmod, raw
 * disk writes, and power commands.
 *
 * Three outcomes, all decided remotely first:
 *   allow: the call runs untouched (no local prompt)
 *   deny:  the call is blocked with the resolver's own reason, without asking
 *   ask:   no remote decision arrived (broker disabled, unreachable, or nobody
 *           answered in time), so the local confirm prompt decides
 *
 * The local prompt on `ask` is deliberate: it is pi's normal interactive
 * behaviour for a dangerous command, and treating an unreachable broker as a
 * hard block would turn a network outage into a wedged session.
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

const APPROVAL_COMMAND = "nucleus-utils";
const CONFIG_PATH = join(homedir(), ".local", "state", "nucleus", "config.json");
// The sources race with finite bounds by default (300 s for hermes, 600 s for
// prompt), so this is the ceiling for the whole wait rather than a limit under
// the gate: 3600 s matches the hook budget the shared hook files declare, and
// pi falls back to its own confirm when it expires.
const EXEC_TIMEOUT_MS = 3_600_000;
const SUMMARY_LIMIT = 200;

const DELETION_WORD_RE = /\b(?:rm|del|rd|rmdir|erase|ri|unlink|shred|remove-item)\b/i;
type Decision = "allow" | "ask" | "deny";
const DECISIONS: readonly string[] = ["allow", "ask", "deny"];
const SOURCES: readonly string[] = [
  "prompt",
  "hermes",
  "all-timeouts",
  "resolver-error",
  "none",
];
const TIMED_OUT_SOURCES: readonly string[] = ["hermes", "prompt"];
const CONTRACT_KEYS: readonly string[] = [
  "version",
  "decision",
  "reason",
  "source",
  "timeouts",
  "timedOutSources",
];

/** The typed decision document, or null when stdout carries no usable decision. */
function parseDecision(stdout: string): { decision: Decision; reason: string } | null {
  try {
    const doc = JSON.parse(stdout.trim().split("\n").pop()?.trim() ?? "") as Record<
      string,
      unknown
    >;
    if (typeof doc !== "object" || doc === null || Array.isArray(doc)) return null;
    // The schema sets additionalProperties: false, so an extra top-level field
    // makes the whole document unusable.
    if (Object.keys(doc).length !== CONTRACT_KEYS.length) return null;
    if (CONTRACT_KEYS.some((key) => !Object.prototype.hasOwnProperty.call(doc, key))) return null;
    if (doc["version"] !== 1) return null;
    if (!DECISIONS.includes(doc["decision"] as string)) return null;
    if (typeof doc["reason"] !== "string") return null;
    if (!SOURCES.includes(doc["source"] as string)) return null;
    const timeouts = doc["timeouts"];
    if (typeof timeouts !== "object" || timeouts === null || Array.isArray(timeouts)) return null;
    const bounds = timeouts as Record<string, unknown>;
    if (bounds["hermes"] !== 300 || bounds["prompt"] !== 600) return null;
    if (!Array.isArray(doc["timedOutSources"])) return null;
    if (!doc["timedOutSources"].every((name) => TIMED_OUT_SOURCES.includes(name as string))) return null;
    return { decision: doc["decision"] as Decision, reason: doc["reason"] as string };
  } catch {
    return null;
  }
}

const RISKY_PATTERNS: ReadonlyArray<readonly [RegExp, string]> = [
  [/\bsudo\b/, "privileged command"],
  [/\bgit\s+push\b/, "git push"],
  [/\|\s*(?:ba|z|k|fi)?sh\b/, "piped to a shell"],
  [/\bchmod\s+-R\b/, "recursive chmod"],
  [/\b(?:mkfs(?:\.\w+)?|dd)\b/, "raw disk write"],
  [/\b(?:shutdown|reboot|halt)\b/, "power command"],
];

/**
 * `harness-notify.enable` is the master kill switch: with it off, this gate must
 * not add prompts pi would not otherwise show. The gate itself
 * (`harness-approval.sources`, `["prompt","hermes"]` by default) is read by the
 * `nucleus-utils harness request-approval` command this extension calls, so
 * an empty list leaves pi's own confirm.
 */
function approvalEnabled(): boolean {
  try {
    const parsed = JSON.parse(readFileSync(CONFIG_PATH, "utf8")) as Record<
      string,
      unknown
    >;
    const section = parsed["harness-notify"];
    if (section && typeof section === "object") {
      return (section as Record<string, unknown>).enable !== false;
    }
    return true;
  } catch {
    // Absent or unreadable config means "not configured", and the declared
    // default for the bridge is enabled.
    return true;
  }
}

/** The reason a call is risky, or null when it is not gated at all. */
function riskyReason(input: unknown): string | null {
  let text: string;
  try {
    text = JSON.stringify(input ?? "");
  } catch {
    return null;
  }
  if (text.length > 4000) text = text.slice(0, 4000);
  if (DELETION_WORD_RE.test(text)) return null;
  for (const [pattern, reason] of RISKY_PATTERNS) {
    if (pattern.test(text)) return reason;
  }
  return null;
}

function summarize(input: unknown): string {
  let text: string;
  try {
    text = JSON.stringify(input ?? "");
  } catch {
    return "(unserializable input)";
  }
  return text.length > SUMMARY_LIMIT
    ? `${text.slice(0, SUMMARY_LIMIT)}…`
    : text;
}

export default function (pi: ExtensionAPI) {
  pi.on("tool_call", async (event, ctx) => {
    if (!approvalEnabled()) return;

    const reason = riskyReason(event.input);
    if (!reason) return;

    const summary = `${event.toolName} (${reason}): ${summarize(event.input)}`;

    let decision: Decision = "ask";
    let decisionReason = "no approval source answered";
    try {
      const result = await pi.exec(
        APPROVAL_COMMAND,
        ["harness", "request-approval", "pi", event.toolName, summary],
        { timeout: EXEC_TIMEOUT_MS },
      );
      if (result.code === 0) {
        const parsed = parseDecision(result.stdout);
        if (parsed !== null) {
          decision = parsed.decision;
          decisionReason = parsed.reason;
        }
      }
    } catch {
      // Broker unreachable: fall through to the local prompt rather than
      // blocking the call.
      decision = "ask";
    }

    if (decision === "allow") return;
    if (decision === "deny") {
      return { block: true, reason: decisionReason };
    }

    const approved = await ctx.ui.confirm(
      "Remote approval unavailable",
      `Run this command?\n\n${summary}`,
    );
    if (!approved) return { block: true, reason: "Blocked by user" };
  });
}
