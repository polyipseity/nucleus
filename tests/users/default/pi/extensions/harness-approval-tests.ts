import { describe, expect, mock, test } from "bun:test";
import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

// CONFIG_PATH is computed at import time from os.homedir(). A mocked homedir
// keeps the fixture config in a temp directory without touching the real home.
const fixtureHome = mkdtempSync(join(tmpdir(), "nucleus-approval-ext-"));
mkdirSync(join(fixtureHome, ".local", "state", "nucleus"), { recursive: true });
writeFileSync(
  join(fixtureHome, ".local", "state", "nucleus", "config.json"),
  JSON.stringify({ "harness-notify": { enable: true } }),
);
mock.module("node:os", () => ({ homedir: () => fixtureHome, tmpdir: () => tmpdir() }));
const { default: installHarnessApproval } = await import(
  "../../../../../src/users/default/pi/extensions/harness-approval.ts"
);

const DENY_REASON = "all approval sources timed out (hermes 300s, prompt 600s)";
const TYPED_DENY = `{"version":1,"decision":"deny","reason":"${DENY_REASON}","source":"all-timeouts","timeouts":{"hermes":300,"prompt":600},"timedOutSources":["hermes","prompt"]}`;
const TYPED_DENY_EXTRA_KEY = `${TYPED_DENY.slice(0, -1)},"extra":"unexpected"}`;
const TYPED_ALLOW =
  '{"version":1,"decision":"allow","reason":"prompt allowed","source":"prompt","timeouts":{"hermes":300,"prompt":600},"timedOutSources":[]}';
const TYPED_ASK =
  '{"version":1,"decision":"ask","reason":"no approval sources enabled","source":"none","timeouts":{"hermes":300,"prompt":600},"timedOutSources":[]}';

type ExecResult = { code: number; stdout: string; stderr: string };
type ApprovalHandler = (
  event: { toolName: string; input: unknown },
  ctx: { ui: { confirm: (title: string, message: string) => Promise<boolean> } },
) => Promise<{ block?: boolean; reason?: string } | undefined>;

function loadHandler(
  result: ExecResult,
  calls?: string[][],
  confirmed = false,
): ApprovalHandler {
  let handler: ApprovalHandler | undefined;
  const pi = {
    on: (name: string, registered: unknown) => {
      if (name === "tool_call") handler = registered as ApprovalHandler;
      return () => {};
    },
    exec: async (command: string, args: string[]) => {
      calls?.push([command, ...args]);
      return result;
    },
  };
  installHarnessApproval(pi as never);
  if (handler === undefined) throw new Error("no tool_call handler registered");
  const captured = handler;
  const ctx = { ui: { confirm: async () => confirmed } };
  return (event) => captured(event, ctx);
}

const riskyEvent = { toolName: "bash", input: { command: "git push origin main" } };

describe("harness-approval typed decision consumer", () => {
  test("a typed deny blocks with the resolver's exact reason", async () => {
    const handler = loadHandler({ code: 0, stdout: `${TYPED_DENY}\n`, stderr: "" });

    await expect(handler(riskyEvent)).resolves.toEqual({
      block: true,
      reason: DENY_REASON,
    });
  });

  test("a typed deny with an extra top-level key is not acted on", async () => {
    const handler = loadHandler(
      { code: 0, stdout: `${TYPED_DENY_EXTRA_KEY}\n`, stderr: "" },
      undefined,
      false,
    );

    await expect(handler(riskyEvent)).resolves.toEqual({
      block: true,
      reason: "Blocked by user",
    });
  });

  test("a typed allow runs the call without prompting", async () => {
    const handler = loadHandler({ code: 0, stdout: `${TYPED_ALLOW}\n`, stderr: "" });

    await expect(handler(riskyEvent)).resolves.toBeUndefined();
  });

  test("a typed ask leaves the local prompt in charge", async () => {
    let confirmed = false;
    let handler: ApprovalHandler | undefined;
    const pi = {
      on: (name: string, registered: unknown) => {
        if (name === "tool_call") handler = registered as ApprovalHandler;
        return () => {};
      },
      exec: async () => ({ code: 0, stdout: `${TYPED_ASK}\n`, stderr: "" }),
    };
    installHarnessApproval(pi as never);
    await handler?.(riskyEvent, {
      ui: {
        confirm: async () => {
          confirmed = true;
          return true;
        },
      },
    });

    expect(confirmed).toBe(true);
  });

  test("a plain word with a stderr detail does not become a deny", async () => {
    const handler = loadHandler(
      { code: 0, stdout: "deny\n", stderr: DENY_REASON },
      undefined,
      true,
    );

    const result = await handler(riskyEvent);
    expect(result).toBeUndefined();
  });

  test("the resolver still receives harness, tool, and summary", async () => {
    const calls: string[][] = [];
    const handler = loadHandler(
      { code: 0, stdout: `${TYPED_ALLOW}\n`, stderr: "" },
      calls,
    );

    await handler(riskyEvent);
    expect(calls).toHaveLength(1);
    expect(calls[0]?.[0]).toBe("nucleus-utils");
    expect(calls[0]?.[1]).toBe("harness");
    expect(calls[0]?.[2]).toBe("request-approval");
    expect(calls[0]?.[3]).toBe("pi");
    expect(calls[0]?.[4]).toBe("bash");
    expect(calls[0]?.[5]).toContain("git push");
  });
});
