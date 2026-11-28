import { describe, expect, mock, test } from "bun:test";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const repoRoot = join(dirname(fileURLToPath(import.meta.url)), "../../../../..");

// The server plugin runs the shared resolver through execFile. A mock child
// process keeps this test on the typed document contract without a live broker.
const DENY_REASON = "all approval sources timed out (hermes 300s, prompt 600s)";
const DENY_DOCUMENT =
  `{"version":1,"decision":"deny","reason":"${DENY_REASON}","source":"all-timeouts","timeouts":{"hermes":300,"prompt":600},"timedOutSources":["hermes","prompt"]}`;
const DENY_WITH_EXTRA_KEY = `${DENY_DOCUMENT.slice(0, -1)},"extra":"unexpected"}`;
let approvalStdout = DENY_DOCUMENT;
let approvalArgs: readonly string[] = [];
type NotificationCall = { event: string; text: string };
let notificationCalls: NotificationCall[] = [];

mock.module("node:child_process", () => ({
  execFile: (
    _file: string,
    args: readonly string[],
    _options: unknown,
    callback: (error: Error | null, result: { stdout: string; stderr: string }) => void,
  ) => {
    approvalArgs = args;
    callback(null, { stdout: `${approvalStdout}\n`, stderr: "" });
  },
  spawn: (_command: string, args: readonly string[]) => {
    if (args[1] === "send-notification") {
      notificationCalls.push({ event: String(args[3]), text: String(args[4]) });
    }
    return { on: () => {}, unref: () => {}, stdin: { on: () => {}, end: () => {} } };
  },
}));
const plugins = [
  {
    name: "harness-notify/server.js",
    path: join(repoRoot, "src/users/default/opencode/plugins/harness-notify/server.js"),
  },
  {
    name: "prompt-tools/tui.js",
    path: join(repoRoot, "src/users/default/opencode/plugins/prompt-tools/tui.js"),
  },
] as const;

function importSpecifiers(source: string): string[] {
  const specifiers: string[] = [];
  const fromPattern = /^import\s[\s\S]*?\sfrom\s+["']([^"']+)["'];?/gm;
  for (const match of source.matchAll(fromPattern)) {
    specifiers.push(match[1]);
  }
  const sideEffectPattern = /^import\s+["']([^"']+)["'];?/gm;
  for (const match of source.matchAll(sideEffectPattern)) {
    specifiers.push(match[1]);
  }
  return [...new Set(specifiers)];
}

describe("opencode v2 plugins", () => {
  test("a typed deny with an extra top-level key is not acted on", async () => {
    approvalStdout = DENY_WITH_EXTRA_KEY;
    notificationCalls = [];
    const replies: unknown[] = [];
    const { default: plugin } = await import(
      join(repoRoot, "src/users/default/opencode/plugins/harness-notify/server.js")
    );
    async function* events() {
      yield {
        type: "permission.asked",
        data: { id: "req-7", sessionID: "sess-7", action: "bash", message: "rm x" },
      };
    }
    const teardown = await plugin.setup({
      location: { directory: "/tmp/project" },
      event: { subscribe: events },
      permission: { reply: async (answer: unknown) => replies.push(answer) },
    });
    await new Promise((resolve) => setTimeout(resolve, 50));
    await teardown();

    expect(replies).toEqual([]);
    expect(
      notificationCalls.some(
        (call) => call.event === "approval" && call.text.includes("no remote answer"),
      ),
    ).toBe(true);
  });

  test("a typed deny reaches permission.reply as reject, not a local ask", async () => {
    approvalStdout = DENY_DOCUMENT;
    const replies: unknown[] = [];
    const { default: plugin } = await import(
      join(repoRoot, "src/users/default/opencode/plugins/harness-notify/server.js")
    );
    async function* events() {
      yield {
        type: "permission.asked",
        data: { id: "req-7", sessionID: "sess-7", action: "bash", message: "rm x" },
      };
    }
    const teardown = await plugin.setup({
      location: { directory: "/tmp/project" },
      event: { subscribe: events },
      permission: { reply: async (answer: unknown) => replies.push(answer) },
    });
    // The plugin starts its subscription without awaiting the first event.
    await new Promise((resolve) => setTimeout(resolve, 50));
    await teardown();

    expect(replies).toEqual([
      { sessionID: "sess-7", requestID: "req-7", decision: "reject" },
    ]);
    expect(approvalArgs).toEqual([
      "harness",
      "request-approval",
      "opencode",
      "bash",
      "project — rm x",
    ]);
  });

  test("a typed deny notifies with the resolver reason and does not fall back to ask", async () => {
    approvalStdout = DENY_DOCUMENT;
    notificationCalls = [];
    const replies: unknown[] = [];
    const { default: plugin } = await import(
      join(repoRoot, "src/users/default/opencode/plugins/harness-notify/server.js")
    );
    async function* events() {
      yield {
        type: "permission.asked",
        data: { id: "req-7", sessionID: "sess-7", action: "bash", message: "rm x" },
      };
    }
    const teardown = await plugin.setup({
      location: { directory: "/tmp/project" },
      event: { subscribe: events },
      permission: { reply: async (answer: unknown) => replies.push(answer) },
    });
    await new Promise((resolve) => setTimeout(resolve, 50));
    await teardown();

    const approvals = notificationCalls.filter((call) => call.event === "approval");
    expect(approvals).toHaveLength(1);
    expect(approvals[0]?.text).toContain(DENY_REASON);
    expect(notificationCalls.some((call) => call.text.includes("no remote answer"))).toBe(false);
    expect(replies).toEqual([
      { sessionID: "sess-7", requestID: "req-7", decision: "reject" },
    ]);
  });

  for (const plugin of plugins) {
    test(`${plugin.name} imports, exports a default plugin, and uses only node: specifiers`, async () => {
      const mod = await import(plugin.path);
      expect(mod.default).toBeDefined();
      const isFunction = typeof mod.default === "function";
      const isPluginObject = typeof mod.default === "object" && mod.default !== null && typeof mod.default.setup === "function";
      expect(isFunction || isPluginObject).toBe(true);

      const source = readFileSync(plugin.path, "utf8");
      const specifiers = importSpecifiers(source);
      expect(specifiers.length).toBeGreaterThan(0);
      for (const specifier of specifiers) {
        expect(specifier.startsWith("node:")).toBe(true);
      }
    });
  }
});
