/**
 * Pi extension that routes pi lifecycle events to the shared harness
 * notification entry point (`harness-notify`, deployed to ~/.local/bin).
 *
 * Two events matter for notification purposes:
 *   - `agent_settled`   — pi will not continue on its own, so the turn is done.
 *                         (`agent_end` is too early: auto-retry, auto-compact
 *                         and queued follow-ups still run afterwards.)
 *   - `ui_prompt_start` — pi is blocked on the user (select/confirm/input/…).
 *
 * Only *when* to speak is decided here; channel selection and message
 * formatting belong to `harness-notify`.  Delivery is best-effort: a failing or
 * slow notification must never break, block, or lengthen a session, so every
 * error is discarded.  pi runs inside srt, so the notification endpoints are
 * allowlisted in src/users/default/srt/settings.json.
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { basename } from "node:path";

const NOTIFY_COMMAND = "harness-notify";
// Bounds the wait at agent settle; any longer and a wedged network call would
// visibly delay the next prompt.
const NOTIFY_TIMEOUT_MS = 15_000;
const FAILED_NOTIFICATION_CAP = 3;

export default function (pi: ExtensionAPI) {
  let failures = 0;

  const notify = async (
    event: "done" | "needs-input",
    text: string,
  ): Promise<void> => {
    if (failures >= FAILED_NOTIFICATION_CAP) return;
    try {
      const result = await pi.exec(NOTIFY_COMMAND, ["pi", event, text], {
        timeout: NOTIFY_TIMEOUT_MS,
      });
      if (result.code !== 0) failures += 1;
    } catch {
      // Intentionally discarded (see module header): notify is best-effort, and
      // a missing or wedged bridge must not surface as a pi error.
      failures += 1;
    }
  };

  pi.on("agent_settled", async (_event, ctx) => {
    await notify("done", `${basename(ctx.cwd)} — turn finished`);
  });

  pi.on("ui_prompt_start", async (event, ctx) => {
    const suffix = event.title ? ` — ${event.title}` : "";
    await notify("needs-input", `${basename(ctx.cwd)}${suffix}`);
  });
}
