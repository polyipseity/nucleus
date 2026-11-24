import { describe, expect, test } from "bun:test";
import { mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  EMPTY_SESSION_MESSAGE,
  NOTHING_TO_CONTINUE_MESSAGE,
  NOTHING_TO_COPY_QUEUED_MESSAGE,
  NOTHING_TO_REPEAT_QUEUED_MESSAGE,
  buildPromptChoices,
  copyTextToClipboard,
  createPromptToolsTuiPlugin,
  extractUserPromptText,
  filterPromptChoices,
  findLastQueuedPrompt,
  findLastSentUserPrompt,
  findSentUserPrompts,
  handleContinue,
  handleCopyUserPrompt,
  handleRepeatUserPrompt,
  nucleusUserRoot,
  opencodeQueuedCommandsDir,
  parsePromptSourceArg,
  promptPreview,
  readQueuedPromptFile,
  readQueuedPromptList,
  registerPromptToolsCommands,
  resolvePromptChoice,
} from "../../../../../src/users/default/opencode/plugins/prompt-tools/tui.js";

type Handler = (args?: string) => unknown | Promise<unknown>;

interface FakeContextOptions {
  readonly messages?: readonly unknown[];
  readonly pending?: readonly unknown[];
  readonly running?: boolean;
  readonly selectResult?: unknown;
  readonly confirmResult?: boolean;
  readonly sessionID?: string | null;
  readonly promptImpl?: (body: unknown) => unknown | Promise<unknown>;
}

function makeContext(options: FakeContextOptions = {}) {
  const printed: string[] = [];
  const replaceCalls: Array<{ render: () => unknown; onClose?: () => void; props?: Record<string, unknown> }> = [];
  const confirmCalls: Array<Record<string, unknown>> = [];
  const promptCalls: unknown[] = [];
  const registered: Array<Record<string, unknown>> = [];

  const context = {
    sessionID: options.sessionID === undefined ? "s1" : options.sessionID,
    client: {
      session: {
        prompt: async (body: unknown) => {
          promptCalls.push(body);
          if (options.promptImpl) {
            return options.promptImpl(body);
          }
          return { ok: true };
        },
      },
    },
    data: {
      session: {
        message: {
          list: async () => options.messages ?? [],
        },
        pending: {
          list: async () => options.pending ?? [],
        },
        status: {
          get: async () => [{ sessionID: options.sessionID === undefined ? "s1" : options.sessionID, status: options.running ? "running" : "idle" }],
        },
      },
    },
    ui: {
      toast: (text: string) => {
        printed.push(String(text));
      },
      print: (text: string) => {
        printed.push(text);
      },
      dialog: {
        replace: (render: () => unknown, onClose?: () => void) => {
          const node = render();
          const props = node && typeof node === "object" ? (node as Record<string, unknown>) : undefined;
          replaceCalls.push({ render, onClose, props });
          if (props) {
            const onSelect = props.onSelect as ((opt: unknown) => void) | undefined;
            // If test explicitly passed selectResult (even undefined means cancel in old tests)
            if (Object.prototype.hasOwnProperty.call(options, "selectResult")) {
              if (options.selectResult !== undefined && options.selectResult !== null && typeof onSelect === "function") {
                const opts = props.options as Array<{ value: string }> | undefined;
                const sel = options.selectResult;
                if (typeof sel === "number" && opts && opts[sel]) {
                  onSelect({ value: opts[sel].value, title: "" });
                } else if (typeof sel === "string") {
                  onSelect({ value: sel, title: "" });
                } else {
                  onSelect({ value: String(sel), title: "" });
                }
              } else if (typeof onSelect === "function" || true) {
                // cancel: call onClose
                if (typeof onClose === "function") onClose();
              }
            } else if (typeof props.onConfirm === "function") {
              confirmCalls.push(props);
              if (options.confirmResult === true) {
                (props.onConfirm as () => void)();
              } else if (options.confirmResult === false) {
                const onCancel = props.onCancel as (() => void) | undefined;
                if (typeof onCancel === "function") onCancel();
                else if (typeof onClose === "function") onClose();
              }
            } else if (typeof onSelect === "function" && typeof onClose === "function") {
              onClose();
            } else if (typeof onClose === "function") {
              onClose();
            }
          } else if (typeof onClose === "function") {
            onClose();
          }
        },
        clear: () => {},
        select: async (opts: Record<string, unknown>) => {
          replaceCalls.push({ render: () => ({ ...opts }), props: opts });
          return options.selectResult;
        },
        confirm: async (opts: Record<string, unknown>) => {
          confirmCalls.push(opts);
          return options.confirmResult ?? false;
        },
      },
      DialogSelect: (props: Record<string, unknown>) => props,
      DialogConfirm: (props: Record<string, unknown>) => props,
    },
    keymap: {
      commands: {
        register: (command: Record<string, unknown>) => {
          registered.push(command);
        },
      },
    },
  };

  function selIsNullish(v: unknown) {
    return v === undefined || v === null;
  }

  return { context, printed, replaceCalls, confirmCalls, promptCalls, registered };
}

function commandHandler(registered: readonly Record<string, unknown>[], name: string): Handler {
  const entry = registered.find((command) => command.name === name);
  const handler = (entry?.run ?? entry?.execute ?? entry?.handler) as Handler | undefined;
  if (!handler) {
    throw new Error(`Command not registered: ${name}`);
  }
  return handler;
}

function makeQueueRoot(files: Record<string, unknown>): string {
  const root = mkdtempSync(join(tmpdir(), "opencode-prompt-tools-queue-"));
  const dir = opencodeQueuedCommandsDir(root);
  mkdirSync(dir, { recursive: true });
  for (const [name, value] of Object.entries(files)) {
    writeFileSync(join(dir, name), typeof value === "string" ? value : JSON.stringify(value), "utf8");
  }
  return root;
}

function cleanup(path: string): void {
  rmSync(path, { recursive: true, force: true });
}

describe("nucleusUserRoot", () => {
  test("derives platform-specific nucleus user roots", () => {
    expect(nucleusUserRoot("darwin", {}, () => "/Users/test")).toBe(
      "/Users/test/Library/Application Support/nucleus",
    );
    expect(nucleusUserRoot("win32", { LOCALAPPDATA: "C:\\Users\\test\\AppData\\Local" }, () => "C:\\Users\\test")).toBe(
      join("C:\\Users\\test\\AppData\\Local", "nucleus"),
    );
    expect(nucleusUserRoot("linux", {}, () => "/home/test")).toBe("/home/test/.local/share/nucleus");
  });
});

describe("parsePromptSourceArg", () => {
  test("defaults to sent", () => {
    expect(parsePromptSourceArg("")).toBe("sent");
    expect(parsePromptSourceArg("   ")).toBe("sent");
    expect(parsePromptSourceArg(undefined as unknown as string)).toBe("sent");
  });

  test("accepts sent, queued, and pick case-insensitively", () => {
    expect(parsePromptSourceArg("sent")).toBe("sent");
    expect(parsePromptSourceArg("queued")).toBe("queued");
    expect(parsePromptSourceArg("pick")).toBe("pick");
    expect(parsePromptSourceArg(" SENT ")).toBe("sent");
    expect(parsePromptSourceArg("Queued")).toBe("queued");
    expect(parsePromptSourceArg("PICK")).toBe("pick");
  });

  test("rejects unknown args", () => {
    expect(parsePromptSourceArg("last")).toEqual({
      error: 'Unknown prompt source "last". Use sent, queued, or pick.',
    });
  });
});

describe("message extraction", () => {
  test("extracts user prompt text from role/content shapes", () => {
    expect(extractUserPromptText({ role: "user", content: "hello" })).toBe("hello");
    expect(
      extractUserPromptText({
        info: { role: "user" },
        parts: [{ type: "text", text: "hello" }, { type: "text", text: "world" }],
      }),
    ).toBe("hello\nworld");
  });

  test("finds last sent user prompt", () => {
    expect(
      findLastSentUserPrompt([
        { role: "user", content: "first" },
        { role: "assistant", content: "reply" },
        { info: { role: "user" }, parts: [{ type: "text", text: "second" }] },
      ]),
    ).toEqual({ source: "sent", text: "second" });
    expect(findLastSentUserPrompt([{ role: "assistant", content: "x" }])).toBeNull();
  });

  test("finds last queued prompt from pending list", () => {
    expect(
      findLastQueuedPrompt([
        { text: "old" },
        { prompt: "newest queued" },
      ]),
    ).toEqual({ source: "queued", text: "newest queued" });
    expect(findLastQueuedPrompt(["  queued string  "])).toEqual({ source: "queued", text: "queued string" });
    expect(findLastQueuedPrompt([{ text: "   " }, 123])).toBeNull();
  });
});

describe("readQueuedPromptFile", () => {
  test("reads newest queued prompt without consuming it", () => {
    const root = makeQueueRoot({
      "100-a.json": { text: "old" },
      "200-b.json": { text: "newest queued" },
      "150-c.json": { text: "middle" },
    });
    try {
      const dir = opencodeQueuedCommandsDir(root);
      expect(readQueuedPromptFile(dir)).toBe("newest queued");
      expect(readQueuedPromptFile(dir)).toBe("newest queued");
    } finally {
      cleanup(root);
    }
  });

  test("returns null for missing, empty, or invalid queue state", () => {
    const root = mkdtempSync(join(tmpdir(), "opencode-prompt-tools-empty-"));
    try {
      expect(readQueuedPromptFile(opencodeQueuedCommandsDir(root))).toBeNull();
      const dir = opencodeQueuedCommandsDir(root);
      mkdirSync(dir, { recursive: true });
      expect(readQueuedPromptFile(dir)).toBeNull();
      writeFileSync(join(dir, "100-a.json"), "{bad json", "utf8");
      expect(readQueuedPromptFile(dir)).toBeNull();
      writeFileSync(join(dir, "200-b.json"), JSON.stringify({ text: "   " }), "utf8");
      expect(readQueuedPromptFile(dir)).toBeNull();
    } finally {
      cleanup(root);
    }
  });
});

describe("command registration", () => {
  test("registers continue, copy-user-prompt, repeat-user-prompt with slash commands", async () => {
    const { context, registered } = makeContext();
    registerPromptToolsCommands(context);

    expect(registered.map((command) => command.name)).toEqual([
      "continue",
      "copy-user-prompt",
      "repeat-user-prompt",
    ]);
    expect((registered[0]?.slash as { name: string }).name).toBe("continue");
    expect((registered[1]?.slash as { name: string; arguments?: boolean })).toEqual({
      name: "copy-user-prompt",
      arguments: true,
    });
    expect((registered[2]?.slash as { name: string; arguments?: boolean })).toEqual({
      name: "repeat-user-prompt",
      arguments: true,
    });
    expect(typeof registered[0]?.run).toBe("function");

    const plugin = createPromptToolsTuiPlugin();
    expect(plugin.id).toBe("prompt-tools");
    await plugin.setup(makeContext().context);
  });
});

describe("picker behavior", () => {
  test("opens dialog.replace for pick even with single candidate, and cancel is silent no-op", async () => {
    const single = makeContext({
      messages: [{ role: "user", content: "only sent" }],
      selectResult: undefined,
    });
    const resultSingle = await resolvePromptChoice("pick", single.context);
    expect(single.replaceCalls.length).toBeGreaterThan(0);
    expect(resultSingle).toBe("cancelled");

    const printed: string[] = [];
    const promptCalls: unknown[] = [];
    await handleCopyUserPrompt("pick", {
      ...makeContext({
        messages: [{ role: "user", content: "only sent" }],
        selectResult: undefined,
      }).context,
      ui: {
        toast: (text: string) => printed.push(text),
        print: (text: string) => printed.push(text),
        dialog: {
          replace: (_render: () => unknown, onClose?: () => void) => {
            onClose?.();
          },
          clear: () => {},
        },
        DialogSelect: (props: Record<string, unknown>) => props,
      },
      client: { session: { prompt: async (body: unknown) => promptCalls.push(body) } },
    } as never);
    expect(printed).toEqual([]);
    expect(promptCalls).toEqual([]);
  });

  test("pick places sent first and can select queued", async () => {
    const queuedOption = 1;
    const { context, replaceCalls } = makeContext({
      messages: [{ role: "user", content: "sent prompt" }],
      pending: [{ text: "queued prompt" }],
      selectResult: queuedOption,
    });
    const result = await resolvePromptChoice("pick", context);
    expect(replaceCalls.length).toBeGreaterThan(0);
    expect(result).toMatchObject({ source: "queued", text: "queued prompt" });
  });
});

describe("prompt choice list and filter", () => {
  test("candidate list holds every sent message and every queued prompt", () => {
    const sent = [
      { text: "first", timestamp: "2026-11-18T10:00:00Z" },
      { text: "second", timestamp: "2026-11-18T10:05:00Z" },
    ];
    const queued = [{ text: "queued one", mtimeMs: Date.parse("2026-11-18T10:03:00Z") }];
    const choices = buildPromptChoices(sent, queued);
    expect(choices.map((c) => c.text)).toEqual(["second", "queued one", "first"]);
  });

  test("queued entries lead when sent messages carry no timestamp", () => {
    const sent = [{ text: "older" }, { text: "newer" }];
    const queued = [{ text: "queued", mtimeMs: 1 }];
    expect(buildPromptChoices(sent, queued).map((c) => c.text)).toEqual(["queued", "newer", "older"]);
  });

  test("filter narrows by case-insensitive substring and empty keeps all", () => {
    const choices = buildPromptChoices([{ text: "Alpha" }, { text: "beta" }], []);
    expect(filterPromptChoices(choices, "ALP").map((c) => c.text)).toEqual(["Alpha"]);
    expect(filterPromptChoices(choices, "").length).toBe(2);
  });
});

describe("copy-user-prompt", () => {
  test("copies last sent prompt by default", async () => {
    const { context, printed } = makeContext({
      messages: [{ role: "user", content: "hello world" }],
    });
    await handleCopyUserPrompt("", context, { copyToClipboard: async () => true });
    expect(printed).toEqual(["Copied sent prompt to clipboard."]);
  });

  test("copies queued prompt when requested", async () => {
    const root = makeQueueRoot({ "200-b.json": { text: "queued text" } });
    try {
      const { context, printed } = makeContext({ messages: [] });
      await handleCopyUserPrompt("queued", context, {
        platform: "linux",
        homeDir: () => "/unused",
        env: {},
        copyToClipboard: async () => true,
        readQueuedPrompt: async () => {
          const text = readQueuedPromptFile(opencodeQueuedCommandsDir(root));
          return text === null ? null : { source: "queued", text };
        },
      });
      expect(printed).toEqual(["Copied queued prompt to clipboard."]);
    } finally {
      cleanup(root);
    }
  });

  test("falls back to visible prompt text when clipboard is unavailable", async () => {
    const { context, printed } = makeContext({
      messages: [{ role: "user", content: "fallback text" }],
    });
    await handleCopyUserPrompt("sent", context, {
      copyToClipboard: async () => false,
      writeToClipboardCommand: async () => false,
    });
    expect(printed).toEqual(["Clipboard unavailable. Prompt:\nfallback text"]);
  });

  test("prints empty and queued-empty states as one line and does nothing else", async () => {
    const empty = makeContext({ messages: [] });
    await handleCopyUserPrompt("sent", empty.context, { copyToClipboard: async () => true });
    expect(empty.printed).toEqual([EMPTY_SESSION_MESSAGE]);

    const noQueued = makeContext({ messages: [{ role: "user", content: "sent" }] });
    await handleCopyUserPrompt("queued", noQueued.context, {
      copyToClipboard: async () => true,
      readQueuedPrompt: async () => null,
    });
    expect(noQueued.printed).toEqual([NOTHING_TO_COPY_QUEUED_MESSAGE]);
  });

  test("reports invalid source argument", async () => {
    const { context, printed } = makeContext({ messages: [] });
    await handleCopyUserPrompt("bogus", context);
    expect(printed).toEqual(['Unknown prompt source "bogus". Use sent, queued, or pick.']);
  });

  test("pick copies selected queued prompt", async () => {
    const { context, printed, replaceCalls } = makeContext({
      messages: [{ role: "user", content: "sent prompt" }],
      pending: [{ text: "queued prompt" }],
      selectResult: 1,
    });
    await handleCopyUserPrompt("pick", context, { copyToClipboard: async () => true });
    expect(replaceCalls.length).toBeGreaterThan(0);
    expect(printed).toEqual(["Copied queued prompt to clipboard."]);
  });
});

describe("repeat-user-prompt", () => {
  test("repeats sent prompt as a new turn when idle", async () => {
    const { context, promptCalls, printed } = makeContext({
      messages: [{ role: "user", content: "repeat me" }],
      running: false,
    });
    await handleRepeatUserPrompt("", context);
    expect(promptCalls).toHaveLength(1);
    expect(JSON.stringify(promptCalls[0])).toContain("repeat me");
    expect(printed).toEqual([]);
  });

  test("repeats queued prompt when requested", async () => {
    const { context, promptCalls } = makeContext({ messages: [], pending: [{ text: "queued repeat" }] });
    await handleRepeatUserPrompt("queued", context);
    expect(promptCalls).toHaveLength(1);
    expect(JSON.stringify(promptCalls[0])).toContain("queued repeat");
  });

  test("confirms while running and sends as new turn when confirmed", async () => {
    const { context, promptCalls, confirmCalls, printed } = makeContext({
      messages: [{ role: "user", content: "stream repeat" }],
      running: true,
      confirmResult: true,
    });
    await handleRepeatUserPrompt("sent", context);
    expect(confirmCalls).toHaveLength(1);
    expect(promptCalls).toHaveLength(1);
    expect(JSON.stringify(promptCalls[0])).toContain("stream repeat");
    expect(printed).toEqual(["Queued sent prompt as a new turn."]);
  });

  test("does not repeat while running when confirmation is declined", async () => {
    const { context, promptCalls, confirmCalls, printed } = makeContext({
      messages: [{ role: "user", content: "stream repeat" }],
      running: true,
      confirmResult: false,
    });
    await handleRepeatUserPrompt("sent", context);
    expect(confirmCalls).toHaveLength(1);
    expect(promptCalls).toEqual([]);
    expect(printed).toEqual([]);
  });

  test("prints empty and queued-empty states", async () => {
    const empty = makeContext({ messages: [] });
    await handleRepeatUserPrompt("", empty.context);
    expect(empty.printed).toEqual([EMPTY_SESSION_MESSAGE]);

    const noQueued = makeContext({ messages: [{ role: "user", content: "sent" }] });
    await handleRepeatUserPrompt("queued", noQueued.context, { readQueuedPrompt: async () => null });
    expect(noQueued.printed).toEqual([NOTHING_TO_REPEAT_QUEUED_MESSAGE]);
  });

  test("pick repeats selected queued prompt", async () => {
    const { context, promptCalls, replaceCalls } = makeContext({
      messages: [{ role: "user", content: "sent prompt" }],
      pending: [{ text: "queued prompt" }],
      selectResult: 1,
    });
    await handleRepeatUserPrompt("pick", context);
    expect(replaceCalls.length).toBeGreaterThan(0);
    expect(promptCalls).toHaveLength(1);
    expect(JSON.stringify(promptCalls[0])).toContain("queued prompt");
  });
});

describe("continue", () => {
  test("sends a space prompt when idle and session has a sent message", async () => {
    const { context, promptCalls, printed } = makeContext({
      messages: [{ role: "user", content: "hello" }],
      running: false,
    });
    await handleContinue("", context);
    expect(promptCalls).toHaveLength(1);
    expect(JSON.stringify(promptCalls[0])).toContain('" "');
    expect(printed).toEqual([]);
  });

  test("prints empty-session message when no sent prompt exists", async () => {
    const { context, promptCalls, printed } = makeContext({ messages: [] });
    await handleContinue("", context);
    expect(promptCalls).toEqual([]);
    expect(printed).toEqual([NOTHING_TO_CONTINUE_MESSAGE]);
  });

  test("queues continue as a new turn when session is running", async () => {
    const { context, promptCalls, printed } = makeContext({
      messages: [{ role: "user", content: "hello" }],
      running: true,
    });
    await handleContinue("", context);
    expect(promptCalls).toHaveLength(1);
    expect(JSON.stringify(promptCalls[0])).toContain('" "');
    expect(printed).toEqual(["Queued /continue as a new turn."]);
  });
});

describe("clipboard helpers", () => {
  test("copyTextToClipboard uses injected copier and falls back", async () => {
    expect(await copyTextToClipboard("hello", { copyToClipboard: async () => true })).toBe(true);
    expect(await copyTextToClipboard("hello", { copyToClipboard: async () => false, writeToClipboardCommand: async () => false })).toBe(false);
  });

  test("uses harness-clipboard on PATH when no custom writer is injected", async () => {
    const root = mkdtempSync(join(tmpdir(), "opencode-harness-clip-"));
    try {
      const bin = join(root, "bin");
      mkdirSync(bin, { recursive: true });
      const capture = join(root, "captured.txt");
      writeFileSync(
        join(bin, "harness-clipboard"),
        `#!/bin/sh\ncat > "${capture}"\n`,
        { encoding: "utf8", mode: 0o755 },
      );
      const prevPath = process.env.PATH ?? "";
      process.env.PATH = `${bin}:${prevPath}`;
      try {
        const ok = await copyTextToClipboard("copy me", { platform: "linux" });
        expect(ok).toBe(true);
        expect(readFileSync(capture, "utf8")).toBe("copy me");
      } finally {
        process.env.PATH = prevPath;
      }
    } finally {
      cleanup(root);
    }
  });

  test("tries platform clipboard commands until one succeeds", async () => {
    const calls: Array<{ command: string; args: readonly string[]; text: string }> = [];
    const ok = await copyTextToClipboard("copy me", {
      platform: "linux",
      writeToClipboardCommand: async (command, args, text) => {
        calls.push({ command, args, text });
        return command === "xclip";
      },
    });
    expect(ok).toBe(true);
    expect(calls.map((call) => call.command)).toEqual(["wl-copy", "xclip"]);
    expect(calls[1]?.args).toEqual(["-selection", "clipboard"]);
  });
});

describe("registered command handlers", () => {
  test("registered handlers execute end-to-end", async () => {
    const { context, registered, promptCalls } = makeContext({
      messages: [{ role: "user", content: "registered repeat" }],
      running: false,
    });
    registerPromptToolsCommands(context);
    await commandHandler(registered, "repeat-user-prompt")("sent");
    expect(promptCalls).toHaveLength(1);
    expect(JSON.stringify(promptCalls[0])).toContain("registered repeat");
  });
});
