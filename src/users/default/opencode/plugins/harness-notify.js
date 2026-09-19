/**
 * OpenCode plugin that routes session lifecycle events to the shared harness
 * notification entry point (`harness-notify`, deployed to ~/.local/bin).
 *
 * Events used (OpenCode's plugin `event` hook carries the server event bus):
 *   - `session.idle`     — the session stopped working: the turn is done.
 *   - `permission.asked` — OpenCode is blocked waiting for a tool permission
 *                          decision, which is exactly "needs input" remotely.
 *   - `session.error`    — the turn failed.
 *
 * Only *when* to speak is decided here; channel selection and message
 * formatting belong to `harness-notify`.  The child process is detached so a
 * slow or wedged notification can never delay the session.
 */

import { spawn } from "node:child_process";
import path from "node:path";

const NOTIFY_COMMAND = "harness-notify";

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

/** Project label for the notification body. */
function projectLabel(directory) {
  return directory ? path.basename(directory) : "opencode";
}

export const HarnessNotifyPlugin = async ({ directory }) => {
  const project = projectLabel(directory);

  return {
    event: async ({ event }) => {
      const properties = event.properties ?? {};
      switch (event.type) {
        case "session.idle":
          notify("done", `${project} — session idle`);
          break;
        case "permission.asked": {
          const title = properties.permission?.title;
          const detail = typeof title === "string" && title !== "" ? ` — ${title}` : "";
          notify("approval", `${project} — permission requested${detail}`);
          break;
        }
        case "session.error":
          notify("error", `${project} — session error`);
          break;
      }
    },
  };
};
