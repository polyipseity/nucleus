/**
 * Pi extension that routes risky tool calls through the shared remote-approval
 * broker (`harness-approval`, deployed to ~/.local/bin).
 *
 * Only a conservative pattern list is gated. Prompting for every tool call would
 * make the agent unusable, and pi already has its own permission model for the
 * rest; the patterns here are the commands a person would want to veto from a
 * phone: recursive deletes, privilege escalation, pushes, piping to a shell,
 * recursive chmod, raw disk writes, and power commands.
 *
 * Three outcomes, all decided remotely first:
 *   allow — the call runs untouched (no local prompt)
 *   deny  — the call is blocked without asking locally
 *   ask   — no remote decision arrived (broker disabled, unreachable, or nobody
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

const APPROVAL_COMMAND = "harness-approval";
const CONFIG_PATH = join(homedir(), ".local", "state", "nucleus", "config.json");
// Must exceed harness-approval's own wait (harness-approval.timeout-seconds,
// default 120) so the broker's timeout — not this one — produces `ask`.
const EXEC_TIMEOUT_MS = 240_000;
const SUMMARY_LIMIT = 200;

const RISKY_PATTERNS: ReadonlyArray<readonly [RegExp, string]> = [
  [/\brm\s+-[A-Za-z]*[rRfF]/, "recursive delete"],
  [/\bsudo\b/, "privileged command"],
  [/\bgit\s+push\b/, "git push"],
  [/\|\s*(?:ba|z|k|fi)?sh\b/, "piped to a shell"],
  [/\bchmod\s+-R\b/, "recursive chmod"],
  [/\b(?:mkfs(?:\.\w+)?|dd)\b/, "raw disk write"],
  [/\b(?:shutdown|reboot|halt)\b/, "power command"],
];

/**
 * `harness-notify.enable` is the single kill switch for the whole bridge: with it
 * off, this gate must not add prompts pi would not otherwise show.
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

    let decision = "ask";
    try {
      const result = await pi.exec(
        APPROVAL_COMMAND,
        ["pi", event.toolName, summary],
        { timeout: EXEC_TIMEOUT_MS },
      );
      if (result.code === 0) {
        const lines = result.stdout.trim().split("\n");
        decision = lines[lines.length - 1]?.trim() ?? "ask";
      }
    } catch {
      // Broker unreachable: fall through to the local prompt rather than
      // blocking the call.
      decision = "ask";
    }

    if (decision === "allow") return;
    if (decision === "deny") {
      return { block: true, reason: "Denied remotely (/harness deny)" };
    }

    const approved = await ctx.ui.confirm(
      "Remote approval unavailable",
      `Run this command?\n\n${summary}`,
    );
    if (!approved) return { block: true, reason: "Blocked by user" };
  });
}
