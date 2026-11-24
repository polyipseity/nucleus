import { describe, expect, test } from "bun:test";
import { mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import registerDefault, {
	EMPTY_SESSION_MESSAGE,
	NOTHING_TO_CONTINUE_MESSAGE,
	NOTHING_TO_COPY_QUEUED_MESSAGE,
	NOTHING_TO_REPEAT_QUEUED_MESSAGE,
	buildPromptChoices,
	claudeQueuedCommandsDir,
	copyTextToClipboard,
	extractUserPromptText,
	filterPromptChoices,
	findLastSentUserPrompt,
	findSentUserPrompts,
	formatPromptChoiceList,
	handleContinue,
	handleCopyUserPrompt,
	handleRepeatUserPrompt,
	nucleusUserRoot,
	parsePromptSourceArg,
	promptPreview,
	readQueuedPromptFile,
	readQueuedPromptList,
	register,
	resolvePromptChoice,
	resolvePromptSource,
	selectPromptChoice,
} from "../../../../../src/users/default/claude/plugins/nucleus-prompt-tools/hooks/register.js";

type CommandRunHandler = (ctx: unknown, event: unknown) => unknown | Promise<unknown>;

interface FakeHarness {
	on: (eventName: string, filter: Record<string, unknown> | ((...args: unknown[]) => unknown), handler?: (...args: unknown[]) => unknown) => void;
	$: {
		command?: { register: (spec: Record<string, unknown>) => void };
		messages?: readonly unknown[];
		isIdle?: () => boolean;
	};
	registeredCommands: Array<Record<string, unknown>>;
	handlers: Map<string, CommandRunHandler>;
	startHandlers: Array<(ctx: unknown) => unknown | Promise<unknown>>;
	emitStart: (ctx?: unknown) => Promise<void>;
	run: (name: string, args?: string, ctx?: unknown) => Promise<unknown>;
}

function makeHarness(options: { messages?: readonly unknown[]; idle?: boolean } = {}): FakeHarness {
	const handlers = new Map<string, CommandRunHandler>();
	const startHandlers: Array<(ctx: unknown) => unknown | Promise<unknown>> = [];
	const registeredCommands: Array<Record<string, unknown>> = [];
	const $: FakeHarness["$"] = {
		command: {
			register: (spec) => {
				registeredCommands.push(spec);
			},
		},
		messages: options.messages ?? [],
		isIdle: () => options.idle ?? true,
	};

	const on: FakeHarness["on"] = (eventName, filterOrHandler, maybeHandler) => {
		if (eventName === "session.start") {
			const handler = (typeof filterOrHandler === "function" ? filterOrHandler : maybeHandler) as
				| ((ctx: unknown) => unknown | Promise<unknown>)
				| undefined;
			if (handler) startHandlers.push(handler);
			return;
		}
		if (eventName === "command.run") {
			const filter = (typeof filterOrHandler === "object" && filterOrHandler !== null
				? (filterOrHandler as { command?: string })
				: {}) as { command?: string };
			if (filter.command && typeof maybeHandler === "function") {
				handlers.set(filter.command, maybeHandler as CommandRunHandler);
			}
		}
	};

	return {
		on,
		$,
		registeredCommands,
		handlers,
		startHandlers,
		async emitStart(ctx = $) {
			for (const handler of startHandlers) {
				await handler(ctx);
			}
		},
		async run(name: string, args = "", ctx = $) {
			const handler = handlers.get(name);
			if (!handler) {
				throw new Error(`No command.run handler for ${name}`);
			}
			return handler(ctx, { args });
		},
	};
}

function makeQueueRoot(files: Record<string, unknown>): string {
	const root = mkdtempSync(join(tmpdir(), "claude-prompt-tools-queue-"));
	const dir = claudeQueuedCommandsDir(root);
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

describe("message extraction and queue reading", () => {
	test("extracts last sent user prompt from messages", () => {
		expect(
			findLastSentUserPrompt([
				{ role: "user", content: "first" },
				{ role: "assistant", content: "reply" },
				{ info: { role: "user" }, parts: [{ type: "text", text: "second" }] },
			]),
		).toEqual({ source: "sent", text: "second" });
		expect(extractUserPromptText({ role: "user", content: "hello" })).toBe("hello");
		expect(findLastSentUserPrompt([{ role: "assistant", content: "x" }])).toBeNull();
	});

	test("reads newest queued prompt without consuming it", () => {
		const root = makeQueueRoot({
			"100-a.json": { text: "old" },
			"200-b.json": { text: "newest queued" },
			"150-c.json": { text: "middle" },
		});
		try {
			const dir = claudeQueuedCommandsDir(root);
			expect(readQueuedPromptFile(dir)).toBe("newest queued");
			expect(readQueuedPromptFile(dir)).toBe("newest queued");
		} finally {
			cleanup(root);
		}
	});

	test("returns null for missing, empty, or invalid queue state", () => {
		const root = mkdtempSync(join(tmpdir(), "claude-prompt-tools-empty-"));
		try {
			expect(readQueuedPromptFile(claudeQueuedCommandsDir(root))).toBeNull();
			const dir = claudeQueuedCommandsDir(root);
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
	test("registers all prompt tool commands on session.start", async () => {
		const harness = makeHarness();
		register(harness.on, { $: harness.$, deps: { readQueuedPromptFile: () => null } });
		expect(harness.registeredCommands).toEqual([]);
		await harness.emitStart(harness.$);
		expect(harness.registeredCommands.map((c) => c.name)).toEqual([
			"continue",
			"copy-user-prompt",
			"repeat-user-prompt",
		]);
		expect(harness.registeredCommands[0]?.description).toBe("Retry or continue the current turn");
		expect(harness.registeredCommands[1]?.argumentHint).toBe("[sent|queued|pick [index]]");
		expect(harness.registeredCommands[2]?.argumentHint).toBe("[sent|queued|pick [index]]");
		expect(typeof harness.handlers.get("continue")).toBe("function");
		expect(typeof harness.handlers.get("copy-user-prompt")).toBe("function");
		expect(typeof harness.handlers.get("repeat-user-prompt")).toBe("function");
		expect(typeof registerDefault).toBe("function");
	});

	test("handles command.run when registered with a ready context", async () => {
		const harness = makeHarness({ messages: [{ role: "user", content: "hello" }] });
		register(harness.on, {
			$: harness.$,
			deps: { readQueuedPromptFile: () => null, copyToClipboard: async () => true },
		});
		await expect(harness.run("copy-user-prompt", "sent", harness.$)).resolves.toEqual({
			text: "Copied sent prompt to clipboard.",
		});
	});
});

describe("resolvePromptChoice and pick behavior", () => {
	test("resolves sent and queued explicitly", () => {
		const root = makeQueueRoot({ "300-c.json": { text: "queued choice" } });
		try {
			const ctx = { messages: [{ role: "user", content: "sent choice" }] };
			const deps = { homeDir: () => "/unused", env: {}, platform: "linux", readQueuedPromptFile: () => readQueuedPromptFile(claudeQueuedCommandsDir(root)) };
			expect(resolvePromptChoice("sent", ctx, deps)).toEqual({ source: "sent", text: "sent choice" });
			expect(resolvePromptChoice("queued", ctx, deps)).toEqual({ source: "queued", text: "queued choice" });
		} finally {
			cleanup(root);
		}
	});

	test("a bare pick prints the numbered list instead of choosing", () => {
		const choices = buildPromptChoices([{ text: "a" }, { text: "b" }], []);
		const out = formatPromptChoiceList(choices);
		expect(out).toContain("1.");
		expect(out).toContain("2.");
		expect(typeof out).toBe("string");
	});

	test("pick with an index selects that candidate and is 1-based", () => {
		const choices = buildPromptChoices([{ text: "a" }, { text: "b" }], []);
		expect(selectPromptChoice(choices, "1").text).toBe("b");
	});

	test("an out-of-range index reports the range instead of choosing", () => {
		const choices = buildPromptChoices([{ text: "a" }], []);
		expect(selectPromptChoice(choices, "9")).toMatchObject({ error: expect.any(String) });
	});

	test("windowed list shows 10 items and a (+N more) line", () => {
		const choices = buildPromptChoices(Array.from({ length: 12 }, (_, i) => ({ text: `p${i}` })), []);
		const out = formatPromptChoiceList(choices);
		expect(out).toContain("10.");
		expect(out).not.toContain("11.");
		expect(out).toContain("(+2 more)");
	});

	test("fuzzy filter ranks subsequence matches and keeps stable ties", () => {
		const choices = [
			{ source: "sent" as const, text: "run git reset" },
			{ source: "sent" as const, text: "alpha bravo" },
			{ source: "sent" as const, text: "queued gpt text" },
		];
		expect(filterPromptChoices(choices, "gpt").map((c) => c.text)).toEqual(["queued gpt text"]);
		const cont = [
			{ source: "sent" as const, text: "context" },
			{ source: "sent" as const, text: "continue work" },
			{ source: "sent" as const, text: "copy text" },
		];
		expect(filterPromptChoices(cont, "cont").map((c) => c.text)).toEqual(["context", "continue work"]);
	});

	test("shared fuzzy fixture cases match filterPromptChoices", () => {
		const fixture = JSON.parse(
			readFileSync(join(process.cwd(), "tests/fixtures/prompt-picker-fuzzy.json"), "utf8"),
		) as { cases: Array<{ query: string; items: string[]; expected: string[] }> };
		for (const c of fixture.cases) {
			const choices = buildPromptChoices(c.items.map((text) => ({ text })), []);
			expect(filterPromptChoices(choices, c.query).map((choice) => choice.text)).toEqual(c.expected);
		}
	});
});

describe("copy-user-prompt", () => {
	test("copies last sent prompt by default", async () => {
		const $ = { messages: [{ role: "user", content: "hello world" }] };
		await expect(handleCopyUserPrompt("", $, { copyToClipboard: async () => true, readQueuedPromptFile: () => null })).resolves.toEqual({
			text: "Copied sent prompt to clipboard.",
		});
	});

	test("copies queued prompt when requested", async () => {
		const $ = { messages: [] };
		await expect(
			handleCopyUserPrompt("queued", $, {
				copyToClipboard: async () => true,
				readQueuedPromptFile: () => "queued text",
			}),
		).resolves.toEqual({ text: "Copied queued prompt to clipboard." });
	});

	test("falls back to visible prompt text when clipboard is unavailable", async () => {
		const $ = { messages: [{ role: "user", content: "fallback text" }] };
		await expect(
			handleCopyUserPrompt("sent", $, {
				copyToClipboard: async () => false,
				writeToClipboardCommand: async () => false,
				readQueuedPromptFile: () => null,
			}),
		).resolves.toEqual({ text: "Clipboard unavailable. Prompt:\nfallback text" });
	});

	test("prints empty and queued-empty states as one line", async () => {
		await expect(handleCopyUserPrompt("sent", { messages: [] }, { readQueuedPromptFile: () => null, copyToClipboard: async () => true })).resolves.toEqual({
			text: EMPTY_SESSION_MESSAGE,
		});
		await expect(
			handleCopyUserPrompt("queued", { messages: [{ role: "user", content: "sent" }] }, { readQueuedPromptFile: () => null, copyToClipboard: async () => true }),
		).resolves.toEqual({ text: NOTHING_TO_COPY_QUEUED_MESSAGE });
	});

	test("reports invalid source argument", async () => {
		await expect(handleCopyUserPrompt("bogus", { messages: [] }, { readQueuedPromptFile: () => null })).resolves.toEqual({
			text: 'Unknown prompt source "bogus". Use sent, queued, or pick.',
		});
	});

	test("pick prints a numbered list and pick with index copies selected prompt", async () => {
		const deps = { copyToClipboard: async () => true, readQueuedPromptFile: () => "queued prompt" };
		const ctx = { messages: [{ role: "user", content: "sent prompt" }] };
		const list = await handleCopyUserPrompt("pick", ctx, deps);
		expect(list.text).toContain("1.");
		expect(list.text).toContain("2.");
		await expect(handleCopyUserPrompt("pick 2", ctx, deps)).resolves.toEqual({ text: "Copied queued prompt to clipboard." });
	});
});

describe("repeat-user-prompt", () => {
	test("returns selected sent prompt as { text } by default", async () => {
		await expect(handleRepeatUserPrompt("", { messages: [{ role: "user", content: "repeat me" }] }, { readQueuedPromptFile: () => null })).resolves.toEqual({
			text: "repeat me",
		});
	});

	test("returns queued prompt when requested", async () => {
		await expect(handleRepeatUserPrompt("queued", { messages: [] }, { readQueuedPromptFile: () => "queued repeat" })).resolves.toEqual({
			text: "queued repeat",
		});
	});

	test("prints empty and queued-empty states", async () => {
		await expect(handleRepeatUserPrompt("", { messages: [] }, { readQueuedPromptFile: () => null })).resolves.toEqual({ text: EMPTY_SESSION_MESSAGE });
		await expect(handleRepeatUserPrompt("queued", { messages: [] }, { readQueuedPromptFile: () => null })).resolves.toEqual({ text: NOTHING_TO_REPEAT_QUEUED_MESSAGE });
	});

	test("pick prints a numbered list and pick with index returns selected prompt", async () => {
		const ctx = { messages: [{ role: "user", content: "sent prompt" }] };
		const depsQueued = { readQueuedPromptFile: () => "queued prompt" };
		const list = await handleRepeatUserPrompt("pick", ctx, depsQueued);
		expect(list.text).toContain("1.");
		expect(list.text).toContain("2.");
		await expect(handleRepeatUserPrompt("pick 2", ctx, depsQueued)).resolves.toEqual({ text: "queued prompt" });
		await expect(handleRepeatUserPrompt("pick 1", ctx, { readQueuedPromptFile: () => null })).resolves.toEqual({ text: "sent prompt" });
	});
});

describe("continue", () => {
	test("returns a space when idle and session has a sent message", async () => {
		await expect(handleContinue("", { messages: [{ role: "user", content: "hello" }], isIdle: () => true }, { readQueuedPromptFile: () => null })).resolves.toEqual({ text: " " });
	});

	test("prints empty-session message when no sent prompt exists", async () => {
		await expect(handleContinue("", { messages: [], isIdle: () => true }, { readQueuedPromptFile: () => null })).resolves.toEqual({
			text: NOTHING_TO_CONTINUE_MESSAGE,
		});
	});

	test("returns a space when busy and session has a sent message", async () => {
		await expect(handleContinue("", { messages: [{ role: "user", content: "hello" }], isIdle: () => false }, { readQueuedPromptFile: () => null })).resolves.toEqual({
			text: " ",
		});
	});
});

describe("clipboard helpers", () => {
	test("copyTextToClipboard uses injected copier and falls back", async () => {
		expect(await copyTextToClipboard("hello", { copyToClipboard: async () => true })).toBe(true);
		expect(await copyTextToClipboard("hello", { copyToClipboard: async () => false, writeToClipboardCommand: async () => false })).toBe(false);
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

describe("end-to-end command.run via fake harness", () => {
	test("copy/continue/repeat command.run handlers return expected results", async () => {
		const harness = makeHarness({ messages: [{ role: "user", content: "e2e prompt" }], idle: true });
		register(harness.on, {
			$: harness.$,
			deps: { readQueuedPromptFile: () => "e2e queued", copyToClipboard: async () => true },
		});
		await expect(harness.run("copy-user-prompt", "sent", harness.$)).resolves.toEqual({ text: "Copied sent prompt to clipboard." });
		await expect(harness.run("repeat-user-prompt", "queued", harness.$)).resolves.toEqual({ text: "e2e queued" });
		await expect(harness.run("continue", "", harness.$)).resolves.toEqual({ text: " " });
		await expect(harness.run("copy-user-prompt", "bogus", harness.$)).resolves.toEqual({
			text: 'Unknown prompt source "bogus". Use sent, queued, or pick.',
		});
	});
});
