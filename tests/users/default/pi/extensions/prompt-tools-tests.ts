import { describe, expect, mock, test } from "bun:test";
import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

mock.module("@earendil-works/pi-tui", () => {
	class Input {
		private value = "";
		focused = false;
		getValue(): string { return this.value; }
		setValue(value: string): void { this.value = value; }
		handleInput(data: string): void {
			if (data === "\x7f" || data === "\b") { this.value = this.value.slice(0, -1); return; }
			if (data === "\x1b[3~") { return; }
			if (data.length === 1 && data >= " " && data !== "\x7f") { this.value += data; }
		}
		render(width: number): string[] { return [this.value.slice(0, width)]; }
		invalidate(): void {}
	}

	class SelectList {
		items: Array<{ value: string; label: string; description?: string }>;
		selectedIndex = 0;
		maxVisible: number;
		theme: { noMatch?: (text: string) => string; scrollInfo?: (text: string) => string; selectedPrefix?: (text: string) => string; selectedText?: (text: string) => string; description?: (text: string) => string };
		onSelect?: (item: { value: string; label: string; description?: string }) => void;
		onCancel?: () => void;
		constructor(items: Array<{ value: string; label: string; description?: string }>, maxVisible: number, theme: any) {
			this.items = items;
			this.maxVisible = maxVisible;
			this.theme = theme;
		}
		setSelectedIndex(index: number): void { this.selectedIndex = index; }
		getSelectedItem() { return this.items[this.selectedIndex] ?? null; }
		invalidate(): void {}
		render(width: number): string[] {
			if (this.items.length === 0) return [(this.theme.noMatch?.("  No matches") ?? "  No matches").slice(0, width)];
			const start = Math.max(0, Math.min(this.selectedIndex - Math.floor(this.maxVisible / 2), this.items.length - this.maxVisible));
			const end = Math.min(start + this.maxVisible, this.items.length);
			const lines: string[] = [];
			for (let i = start; i < end; i++) {
				const item = this.items[i];
				const isSelected = i === this.selectedIndex;
				const prefix = isSelected ? (this.theme.selectedPrefix?.("> ") ?? "> ") : "  ";
				const label = isSelected ? (this.theme.selectedText?.(item.label) ?? item.label) : item.label;
				lines.push(`${prefix}${label}`.slice(0, width));
			}
			if (start > 0 || end < this.items.length) lines.push(`(${this.selectedIndex + 1}/${this.items.length})`.slice(0, width));
			return lines;
		}
		handleInput(data: string): void {
			if (data === "\x1b[A" || data === "\x1bOA") { this.selectedIndex = this.items.length === 0 ? 0 : Math.max(0, this.selectedIndex - 1); return; }
			if (data === "\x1b[B" || data === "\x1bOB") { this.selectedIndex = this.items.length === 0 ? 0 : Math.min(this.items.length - 1, this.selectedIndex + 1); return; }
			if (data === "\r" || data === "\n") { const item = this.getSelectedItem(); if (item) this.onSelect?.(item); return; }
			if (data === "\x1b" || data === "\x1b\x1b") { this.onCancel?.(); }
		}
	}

	function fuzzyMatch(query: string, text: string) {
		const q = query.toLower();
		const t = text.toLowerCase();
		let qi = 0;
		let score = 0;
		for (let ti = 0; ti < t.length && qi < q.length; ti++) {
			if (t[ti] === q[qi]) { score += ti; qi++; }
		}
		return { matches: qi === q.length, score };
	}

	function fuzzyFilter<T>(items: T[], query: string, getText: (item: T) => string): T[] {
		if (!query) return [...items];
		const tokens = query.trim().split(/\s+/).filter(Boolean);
		if (tokens.length === 0) return [...items];
		return items
			.map((item) => {
				const text = getText(item);
				let total = 0;
				for (const token of tokens) {
					const m = fuzzyMatch(token, text);
					if (!m.matches) return null;
					total += m.score;
				}
				return { item, total };
			})
			.filter((x): x is { item: T; total: number } => x !== null)
			.sort((a, b) => a.total - b.total)
			.map((x) => x.item);
	}

	function truncateToWidth(text: string, width: number, ellipsis = ""): string {
		if (width <= 0) return "";
		if (text.length <= width) return text;
		const e = ellipsis.slice(0, width);
		return text.slice(0, Math.max(0, width - e.length)) + e;
	}

	return { Input, SelectList, fuzzyFilter, truncateToWidth };
});

mock.module("@earendil-works/pi-coding-agent", () => ({
	getSelectListTheme: () => ({
		selectedPrefix: (text: string) => text,
		selectedText: (text: string) => text,
		description: (text: string) => text,
		scrollInfo: (text: string) => text,
		noMatch: (text: string) => text,
	}),
}));

import promptTools, {
	EMPTY_SESSION_MESSAGE,
	NOTHING_TO_CONTINUE_MESSAGE,
	NOTHING_TO_COPY_QUEUED_MESSAGE,
	NOTHING_TO_REPEAT_QUEUED_MESSAGE,
	buildPromptChoices,
	copyTextToClipboard,
	createPromptPickerComponent,
	createPromptToolsExtension,
	extractUserMessageText,
	filterPromptChoices,
	findLastSentUserPrompt,
	findSentUserPrompts,
	handleContinue,
	handleCopyUserPrompt,
	handleRepeatUserPrompt,
	nucleusUserRoot,
	parsePromptSourceArg,
	piQueuedCommandsDir,
	pickPromptChoice,
	promptPreview,
	readQueuedPrompt,
	readQueuedPromptList,
	resolvePromptChoice,
	type PromptChoice,
	type PromptToolsDeps,
} from "../../../../../src/users/default/pi/extensions/prompt-tools.ts";

type CommandHandler = (args: string, ctx: unknown) => Promise<void> | void;

interface RegisteredCommands {
	readonly continueCommand?: { description: string; handler: CommandHandler };
	readonly copyCommand?: { description: string; handler: CommandHandler };
	readonly repeatCommand?: { description: string; handler: CommandHandler };
}

function registerExtension(deps: PromptToolsDeps = {}): {
	commands: RegisteredCommands;
	sentMessages: Array<{ content: unknown; options?: unknown }>;
	pi: unknown;
} {
	const commands: RegisteredCommands = {};
	const sentMessages: Array<{ content: unknown; options?: unknown }> = [];
	const pi = {
		on: () => () => {},
		registerCommand: (name: string, options: { description: string; handler: CommandHandler }) => {
			if (name === "continue") {
				(commands as { continueCommand?: unknown }).continueCommand = options;
			} else if (name === "copy-user-prompt") {
				(commands as { copyCommand?: unknown }).copyCommand = options;
			} else if (name === "repeat-user-prompt") {
				(commands as { repeatCommand?: unknown }).repeatCommand = options;
			}
		},
		sendUserMessage: (content: unknown, options?: unknown) => {
			sentMessages.push({ content, options });
		},
	};
	createPromptToolsExtension(deps)(pi as never);
	return { commands, sentMessages, pi };
}

function makeContext(options: {
	branch?: readonly unknown[];
	idle?: boolean;
	selectResult?: string | undefined;
	confirmResult?: boolean;
	waitForIdle?: () => Promise<void>;
} = {}): {
	ctx: unknown;
	notifications: Array<[string, string]>;
	selectCalls: Array<[string, string[]]>;
	confirmCalls: Array<[string, string]>;
} {
	const notifications: Array<[string, string]> = [];
	const selectCalls: Array<[string, string[]]> = [];
	const confirmCalls: Array<[string, string]> = [];
	const ctx = {
		hasUI: true,
		isIdle: () => options.idle ?? true,
		...(options.waitForIdle ? { waitForIdle: options.waitForIdle } : {}),
		sessionManager: {
			getBranch: () => options.branch ?? [],
		},
		ui: {
			notify: (message: string, type: string = "info") => notifications.push([message, type]),
			select: async (title: string, values: string[]) => {
				selectCalls.push([title, values]);
				return options.selectResult;
			},
			confirm: async (title: string, message: string) => {
				confirmCalls.push([title, message]);
				return options.confirmResult ?? false;
			},
		},
	};
	return { ctx, notifications, selectCalls, confirmCalls };
}

function makeQueueRoot(files: Record<string, unknown>): string {
	const root = mkdtempSync(join(tmpdir(), "prompt-tools-queue-"));
	const dir = piQueuedCommandsDir(root);
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

describe("extractUserMessageText", () => {
	test("returns string content", () => {
		expect(extractUserMessageText("hello")).toBe("hello");
	});

	test("joins text blocks from content arrays", () => {
		expect(
			extractUserMessageText([
				{ type: "text", text: "hello" },
				{ type: "image", data: "x" },
				{ type: "text", text: "world" },
			]),
		).toBe("hello\nworld");
	});

	test("returns null for non-text content", () => {
		expect(extractUserMessageText([{ type: "image", data: "x" }])).toBeNull();
		expect(extractUserMessageText(123)).toBeNull();
	});
});

describe("findLastSentUserPrompt", () => {
	test("resolves the last sent user-role message from branch", () => {
		const branch = [
			{ type: "message", message: { role: "user", content: "first" } },
			{ type: "message", message: { role: "assistant", content: [{ type: "text", text: "reply" }] } },
			{ type: "message", message: { role: "user", content: [{ type: "text", text: "second" }] } },
			{ type: "custom", customType: "x", data: {} },
		];
		expect(findLastSentUserPrompt(branch)).toEqual({ source: "sent", text: "second" });
	});

	test("returns null when there is no user message", () => {
		expect(
			findLastSentUserPrompt([
				{ type: "message", message: { role: "assistant", content: [{ type: "text", text: "hi" }] } },
			]),
		).toBeNull();
		expect(findLastSentUserPrompt([])).toBeNull();
	});
});

describe("readQueuedPrompt", () => {
	test("reads the newest queued prompt by lexicographic filename", () => {
		const root = makeQueueRoot({
			"100-a.json": { text: "old" },
			"200-b.json": { text: "newest queued" },
			"150-c.json": { text: "middle" },
		});
		try {
			expect(readQueuedPrompt(piQueuedCommandsDir(root))).toBe("newest queued");
		} finally {
			cleanup(root);
		}
	});

	test("does not consume queued prompts", () => {
		const root = makeQueueRoot({ "100-a.json": { text: "keep me" } });
		try {
			const dir = piQueuedCommandsDir(root);
			expect(readQueuedPrompt(dir)).toBe("keep me");
			expect(readQueuedPrompt(dir)).toBe("keep me");
		} finally {
			cleanup(root);
		}
	});

	test("returns null for missing, empty, or invalid queue state", () => {
		const root = mkdtempSync(join(tmpdir(), "prompt-tools-empty-"));
		try {
			expect(readQueuedPrompt(piQueuedCommandsDir(root))).toBeNull();
			const dir = piQueuedCommandsDir(root);
			mkdirSync(dir, { recursive: true });
			expect(readQueuedPrompt(dir)).toBeNull();
			writeFileSync(join(dir, "100-a.json"), "{bad json", "utf8");
			expect(readQueuedPrompt(dir)).toBeNull();
			writeFileSync(join(dir, "200-b.json"), JSON.stringify({ text: "   " }), "utf8");
			expect(readQueuedPrompt(dir)).toBeNull();
		} finally {
			cleanup(root);
		}
	});
});

describe("pickPromptChoice", () => {
	test("highlights last sent by placing it first when both sets exist", async () => {
		const { ctx, selectCalls } = makeContext({ selectResult: "Sent: last sent" });
		const result = await pickPromptChoice(
			{ source: "sent", text: "last sent" },
			{ source: "queued", text: "queued prompt" },
			(ctx as { ui: { select: (title: string, options: string[]) => Promise<string | undefined> } }).ui as never,
		);
		expect(selectCalls).toHaveLength(1);
		expect(selectCalls[0]?.[0]).toBe("Select prompt");
		expect(selectCalls[0]?.[1][0]).toContain("Sent:");
		expect(selectCalls[0]?.[1][1]).toContain("Queued:");
		expect(result).toEqual({ source: "sent", text: "last sent" });
	});

	test("can select queued prompt from picker", async () => {
		const queuedOption = `Queued: ${promptPreview("queued prompt")}`;
		const { ctx } = makeContext({ selectResult: queuedOption });
		const result = await pickPromptChoice(
			{ source: "sent", text: "last sent" },
			{ source: "queued", text: "queued prompt" },
			(ctx as { ui: { select: (title: string, options: string[]) => Promise<string | undefined> } }).ui as never,
		);
		expect(result).toEqual({ source: "queued", text: "queued prompt" });
	});

	test("opens picker for single available choice and can select it", async () => {
		const sentOption = `Sent: ${promptPreview("only sent")}`;
		const { ctx, selectCalls } = makeContext({ selectResult: sentOption });
		const result = await pickPromptChoice(
			{ source: "sent", text: "only sent" },
			null,
			(ctx as { ui: { select: (title: string, options: string[]) => Promise<string | undefined> } }).ui as never,
		);
		expect(selectCalls).toHaveLength(1);
		expect(selectCalls[0]?.[0]).toBe("Select prompt");
		expect(result).toEqual({ source: "sent", text: "only sent" });
	});

	test("returns cancelled when single-choice picker is cancelled", async () => {
		const { ctx, selectCalls } = makeContext({ selectResult: undefined });
		const result = await pickPromptChoice(
			{ source: "sent", text: "only sent" },
			null,
			(ctx as { ui: { select: (title: string, options: string[]) => Promise<string | undefined> } }).ui as never,
		);
		expect(selectCalls).toHaveLength(1);
		expect(result).toBe("cancelled");
	});

	test("returns cancelled when picker selection is cancelled", async () => {
		const { ctx } = makeContext({ selectResult: undefined });
		const result = await pickPromptChoice(
			{ source: "sent", text: "last sent" },
			{ source: "queued", text: "queued prompt" },
			(ctx as { ui: { select: (title: string, options: string[]) => Promise<string | undefined> } }).ui as never,
		);
		expect(result).toBe("cancelled");
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

describe("copyTextToClipboard", () => {
	test("uses injected clipboard writer and falls back on failure", async () => {
		expect(await copyTextToClipboard("hello", { copyToClipboard: async () => true })).toBe(true);
		expect(await copyTextToClipboard("hello", { copyToClipboard: async () => false })).toBe(false);
	});

	test("tries platform clipboard commands until one succeeds", async () => {
		const calls: Array<{ command: string; args: readonly string[]; text: string }> = [];
		const ok = await copyTextToClipboard("copy me", {
			platform: "linux",
			writeToCommandStdin: async (command, args, text) => {
				calls.push({ command, args, text });
				return command === "xclip";
			},
		});
		expect(ok).toBe(true);
		expect(calls.map((call) => call.command)).toEqual(["wl-copy", "xclip"]);
		expect(calls[1]?.args).toEqual(["-selection", "clipboard"]);
	});
});

describe("copy-user-prompt", () => {
	test("copies last sent prompt by default", async () => {
		const { commands } = registerExtension({ copyToClipboard: async () => true });
		const { ctx, notifications } = makeContext({
			branch: [{ type: "message", message: { role: "user", content: "hello world" } }],
		});
		await commands.copyCommand?.handler("", ctx);
		expect(notifications).toEqual([["Copied sent prompt to clipboard.", "info"]]);
	});

	test("copies queued prompt when requested", async () => {
		const root = makeQueueRoot({ "200-b.json": { text: "queued text" } });
		try {
			const { commands } = registerExtension({
				env: { ...process.env, HOME: "/tmp/unused" },
				homeDir: () => "/unused",
				platform: "linux",
				copyToClipboard: async () => true,
				readQueuedPrompt: () => readQueuedPrompt(piQueuedCommandsDir(root)),
			});
			const { ctx, notifications } = makeContext({ branch: [] });
			await commands.copyCommand?.handler("queued", ctx);
			expect(notifications).toEqual([["Copied queued prompt to clipboard.", "info"]]);
		} finally {
			cleanup(root);
		}
	});

	test("falls back to selectable text when clipboard is unavailable", async () => {
		const { commands } = registerExtension({ copyToClipboard: async () => false });
		const { ctx, notifications } = makeContext({
			branch: [{ type: "message", message: { role: "user", content: "fallback text" } }],
		});
		await commands.copyCommand?.handler("sent", ctx);
		expect(notifications).toEqual([["Clipboard unavailable. Prompt:\nfallback text", "info"]]);
	});

	test("prints empty-session message when no sent prompt exists", async () => {
		const { commands } = registerExtension({ copyToClipboard: async () => true });
		const { ctx, notifications } = makeContext({ branch: [] });
		await commands.copyCommand?.handler("sent", ctx);
		expect(notifications).toEqual([[EMPTY_SESSION_MESSAGE, "info"]]);
	});

	test("prints queued-empty message when no queued prompt exists", async () => {
		const { commands } = registerExtension({ copyToClipboard: async () => true, readQueuedPrompt: () => null });
		const { ctx, notifications } = makeContext({ branch: [{ type: "message", message: { role: "user", content: "sent" } }] });
		await commands.copyCommand?.handler("queued", ctx);
		expect(notifications).toEqual([[NOTHING_TO_COPY_QUEUED_MESSAGE, "info"]]);
	});

	test("supports pick and copies selected queued prompt", async () => {
		const queuedOption = `Queued: ${promptPreview("queued prompt")}`;
		const { commands } = registerExtension({
			copyToClipboard: async () => true,
			readQueuedPrompt: () => "queued prompt",
		});
		const { ctx, notifications, selectCalls } = makeContext({
			branch: [{ type: "message", message: { role: "user", content: "sent prompt" } }],
			selectResult: queuedOption,
		});
		await commands.copyCommand?.handler("pick", ctx);
		expect(selectCalls[0]?.[1][0]).toContain("Sent:");
		expect(notifications).toEqual([["Copied queued prompt to clipboard.", "info"]]);
	});

	test("reports invalid source argument", async () => {
		const { commands } = registerExtension({ copyToClipboard: async () => true });
		const { ctx, notifications } = makeContext({ branch: [] });
		await commands.copyCommand?.handler("bogus", ctx);
		expect(notifications).toEqual([['Unknown prompt source "bogus". Use sent, queued, or pick.', "error"]]);
	});
});

describe("repeat-user-prompt", () => {
	test("resubmits sent prompt as a new user turn by default when idle", async () => {
		const { commands, sentMessages } = registerExtension();
		const { ctx, notifications } = makeContext({
			branch: [{ type: "message", message: { role: "user", content: "repeat me" } }],
			idle: true,
		});
		await commands.repeatCommand?.handler("", ctx);
		expect(sentMessages).toEqual([{ content: "repeat me", options: undefined }]);
		expect(notifications).toEqual([]);
	});

	test("resubmits queued prompt when requested", async () => {
		const { commands, sentMessages } = registerExtension({ readQueuedPrompt: () => "queued repeat" });
		const { ctx } = makeContext({ branch: [], idle: true });
		await commands.repeatCommand?.handler("queued", ctx);
		expect(sentMessages).toEqual([{ content: "queued repeat", options: undefined }]);
	});

	test("asks for confirmation while streaming and sends as follow-up when confirmed", async () => {
		const { commands, sentMessages } = registerExtension();
		const { ctx, confirmCalls, notifications } = makeContext({
			branch: [{ type: "message", message: { role: "user", content: "stream repeat" } }],
			idle: false,
			confirmResult: true,
		});
		await commands.repeatCommand?.handler("sent", ctx);
		expect(confirmCalls).toHaveLength(1);
		expect(sentMessages).toEqual([{ content: "stream repeat", options: { deliverAs: "followUp" } }]);
		expect(notifications).toEqual([["Queued sent prompt as a follow-up turn.", "info"]]);
	});

	test("does not repeat while streaming when confirmation is declined", async () => {
		const { commands, sentMessages } = registerExtension();
		const { ctx, confirmCalls } = makeContext({
			branch: [{ type: "message", message: { role: "user", content: "stream repeat" } }],
			idle: false,
			confirmResult: false,
		});
		await commands.repeatCommand?.handler("sent", ctx);
		expect(confirmCalls).toHaveLength(1);
		expect(sentMessages).toEqual([]);
	});

	test("prints empty-session message when no sent prompt exists", async () => {
		const { commands, sentMessages } = registerExtension();
		const { ctx, notifications } = makeContext({ branch: [] });
		await commands.repeatCommand?.handler("", ctx);
		expect(sentMessages).toEqual([]);
		expect(notifications).toEqual([[EMPTY_SESSION_MESSAGE, "info"]]);
	});

	test("prints queued-empty message when no queued prompt exists", async () => {
		const { commands, sentMessages } = registerExtension({ readQueuedPrompt: () => null });
		const { ctx, notifications } = makeContext({ branch: [] });
		await commands.repeatCommand?.handler("queued", ctx);
		expect(sentMessages).toEqual([]);
		expect(notifications).toEqual([[NOTHING_TO_REPEAT_QUEUED_MESSAGE, "info"]]);
	});

	test("supports pick and repeats selected queued prompt", async () => {
		const queuedOption = `Queued: ${promptPreview("queued prompt")}`;
		const { commands, sentMessages } = registerExtension({ readQueuedPrompt: () => "queued prompt" });
		const { ctx, selectCalls } = makeContext({
			branch: [{ type: "message", message: { role: "user", content: "sent prompt" } }],
			selectResult: queuedOption,
		});
		await commands.repeatCommand?.handler("pick", ctx);
		expect(selectCalls).toHaveLength(1);
		expect(sentMessages).toEqual([{ content: "queued prompt", options: undefined }]);
	});

	test("supports pick and repeats selected sent prompt", async () => {
		const sentOption = `Sent: ${promptPreview("sent prompt")}`;
		const { commands, sentMessages } = registerExtension({ readQueuedPrompt: () => "queued prompt" });
		const { ctx, selectCalls } = makeContext({
			branch: [{ type: "message", message: { role: "user", content: "sent prompt" } }],
			selectResult: sentOption,
		});
		await commands.repeatCommand?.handler("pick", ctx);
		expect(selectCalls[0]?.[1][0]).toContain("Sent:");
		expect(sentMessages).toEqual([{ content: "sent prompt", options: undefined }]);
	});

	test("waits for idle during compaction then repeats confirmed prompt", async () => {
		let waited = false;
		let sentBeforeWaitResolved = false;
		const sentMessages: Array<{ content: unknown; options?: unknown }> = [];
		const notifications: Array<[string, string]> = [];
		const confirmCalls: Array<[string, string]> = [];
		const ctx = {
			hasUI: true,
			isIdle: () => false,
			waitForIdle: async () => {
				waited = true;
			},
			sessionManager: {
				getBranch: () => [{ type: "message", message: { role: "user", content: "repeat me" } }],
			},
			ui: {
				notify: (message: string, type: string = "info") => notifications.push([message, type]),
				select: async () => undefined,
				confirm: async (title: string, message: string) => {
					confirmCalls.push([title, message]);
					return true;
				},
			},
		};
		const pi = {
			sendUserMessage: (content: unknown, options?: unknown) => {
				if (!waited) {
					sentBeforeWaitResolved = true;
				}
				sentMessages.push({ content, options });
			},
		};
		await handleRepeatUserPrompt("sent", ctx as never, pi as never, { isCompacting: () => true });
		expect(confirmCalls).toHaveLength(1);
		expect(waited).toBe(true);
		expect(sentBeforeWaitResolved).toBe(false);
		expect(sentMessages).toEqual([{ content: "repeat me", options: undefined }]);
		expect(notifications).toEqual([["Queued sent prompt.", "info"]]);
	});
});

describe("continue", () => {
	test("sends a space message when idle and session has a sent message", async () => {
		const { commands, sentMessages } = registerExtension();
		const { ctx, notifications } = makeContext({
			branch: [{ type: "message", message: { role: "user", content: "hello" } }],
			idle: true,
		});
		await commands.continueCommand?.handler("", ctx);
		expect(sentMessages).toEqual([{ content: " ", options: undefined }]);
		expect(notifications).toEqual([]);
	});

	test("prints empty-session message when no sent prompt exists", async () => {
		const { commands, sentMessages } = registerExtension();
		const { ctx, notifications } = makeContext({ branch: [], idle: true });
		await commands.continueCommand?.handler("", ctx);
		expect(sentMessages).toEqual([]);
		expect(notifications).toEqual([[NOTHING_TO_CONTINUE_MESSAGE, "info"]]);
	});

	test("queues continue as follow-up when agent is streaming", async () => {
		const { commands, sentMessages } = registerExtension();
		const { ctx, notifications } = makeContext({
			branch: [{ type: "message", message: { role: "user", content: "hello" } }],
			idle: false,
		});
		await commands.continueCommand?.handler("", ctx);
		expect(sentMessages).toEqual([{ content: " ", options: { deliverAs: "followUp" } }]);
		expect(notifications).toEqual([["Queued /continue.", "info"]]);
	});

	test("waits for idle during compaction then continues", async () => {
		let waited = false;
		let sentBeforeWaitResolved = false;
		const sentMessages: Array<{ content: unknown; options?: unknown }> = [];
		const notifications: Array<[string, string]> = [];
		const ctx = {
			hasUI: true,
			isIdle: () => false,
			waitForIdle: async () => {
				waited = true;
			},
			sessionManager: {
				getBranch: () => [{ type: "message", message: { role: "user", content: "hello" } }],
			},
			ui: {
				notify: (message: string, type: string = "info") => notifications.push([message, type]),
				select: async () => undefined,
				confirm: async () => false,
			},
		};
		const pi = {
			sendUserMessage: (content: unknown, options?: unknown) => {
				if (!waited) {
					sentBeforeWaitResolved = true;
				}
				sentMessages.push({ content, options });
			},
		};
		await handleContinue("", ctx as never, pi as never, { isCompacting: () => true });
		expect(waited).toBe(true);
		expect(sentBeforeWaitResolved).toBe(false);
		expect(sentMessages).toEqual([{ content: " ", options: undefined }]);
		expect(notifications).toEqual([["Queued /continue.", "info"]]);
	});
});

describe("default export", () => {
	test("registers all prompt tool commands", () => {
		const { commands } = registerExtension();
		expect(commands.continueCommand?.description).toBe("Retry or continue the current turn");
		expect(commands.copyCommand?.description).toBe("Copy a sent or queued prompt (default: sent)");
		expect(commands.repeatCommand?.description).toBe(
			"Resubmit a sent or queued prompt as a new user turn (default: sent)",
		);
		expect(typeof promptTools).toBe("function");
	});
});

describe("resolvePromptChoice", () => {
	test("resolves sent and queued from provided sources", async () => {
		const root = makeQueueRoot({ "300-c.json": { text: "queued choice" } });
		try {
			const deps: PromptToolsDeps = {
				readQueuedPrompt: () => readQueuedPrompt(piQueuedCommandsDir(root)),
			};
			const { ctx } = makeContext({
				branch: [{ type: "message", message: { role: "user", content: "sent choice" } }],
			});
			await expect(resolvePromptChoice("sent", ctx as never, deps)).resolves.toEqual({
				source: "sent",
				text: "sent choice",
			});
			await expect(resolvePromptChoice("queued", ctx as never, deps)).resolves.toEqual({
				source: "queued",
				text: "queued choice",
			});
		} finally {
			cleanup(root);
		}
	});

	test("pick returns empty-session null when neither source exists", async () => {
		const { ctx } = makeContext({ branch: [] });
		await expect(resolvePromptChoice("pick", ctx as never, { readQueuedPrompt: () => null })).resolves.toBeNull();
	});
});

describe("handle helpers", () => {
	test("handleCopyUserPrompt and handleRepeatUserPrompt accept explicit context objects", async () => {
		const { notifications } = makeContext({ branch: [] });
		const ui = {
			notify: (message: string, type: string = "info") => notifications.push([message, type]),
			select: async () => undefined,
			confirm: async () => false,
		};
		const ctx = {
			hasUI: true,
			isIdle: () => true,
			sessionManager: { getBranch: () => [] },
			ui,
		};
		await handleCopyUserPrompt("sent", ctx as never, { copyToClipboard: async () => true });
		await handleRepeatUserPrompt("sent", ctx as never, { sendUserMessage: () => {} }, { readQueuedPrompt: () => null });
		await handleContinue("", ctx as never, { sendUserMessage: () => {} });
		expect(notifications).toEqual([
			[EMPTY_SESSION_MESSAGE, "info"],
			[EMPTY_SESSION_MESSAGE, "info"],
			[NOTHING_TO_CONTINUE_MESSAGE, "info"],
		]);
	});
});

function makePickerDeps() {
	let renders = 0;
	const tui = { requestRender: () => { renders += 1; } };
	const piHostModule = {
		getSelectListTheme: () => ({
			selectedPrefix: (text: string) => text,
			selectedText: (text: string) => text,
			description: (text: string) => text,
			scrollInfo: (text: string) => text,
			noMatch: (text: string) => text,
		}),
	};
	const keybindings = {
		matches: (data: string, binding: string) =>
			binding === "tui.select.cancel" && (data === "\x1b" || data === "\x03"),
	};
	const piTuiModule = {
		Input: class {
			private value = "";
			focused = false;
			getValue() { return this.value; }
			setValue(value: string) { this.value = value; }
			handleInput(data: string) {
				if (data === "\x7f" || data === "\b") { this.value = this.value.slice(0, -1); return; }
				if (data === "\x1b[3~") { return; }
				if (data.length === 1 && data >= " " && data !== "\x7f") { this.value += data; }
			}
			render(width: number) { return [this.value.slice(0, width)]; }
			invalidate() {}
		},
		SelectList: class {
			items: any[];
			selectedIndex = 0;
			maxVisible: number;
			theme: any;
			onSelect?: (item: any) => void;
			onCancel?: () => void;
			constructor(items: any[], maxVisible: number, theme: any) { this.items = items; this.maxVisible = maxVisible; this.theme = theme; }
			setSelectedIndex(index: number) { this.selectedIndex = index; }
			getSelectedIndex() { return this.selectedIndex; }
			getSelectedItem() { return this.items[this.selectedIndex] ?? null; }
			invalidate() {}
			render(width: number) {
				if (this.items.length === 0) return [(this.theme.noMatch?.("  No matches") ?? "  No matches").slice(0, width)];
				const start = Math.max(0, Math.min(this.selectedIndex - Math.floor(this.maxVisible / 2), this.items.length - this.maxVisible));
				const end = Math.min(start + this.maxVisible, this.items.length);
				const lines: string[] = [];
				for (let i = start; i < end; i++) {
					const item = this.items[i];
					const isSelected = i === this.selectedIndex;
					const prefix = isSelected ? (this.theme.selectedPrefix?.("> ") ?? "> ") : "  ";
					const label = isSelected ? (this.theme.selectedText?.(item.label) ?? item.label) : item.label;
					lines.push(`${prefix}${label}`.slice(0, width));
				}
				if (start > 0 || end < this.items.length) lines.push(`(${this.selectedIndex + 1}/${this.items.length})`.slice(0, width));
				return lines;
			}
			handleInput(data: string) {
				if (data === "\x1b[A" || data === "\x1bOA") { this.selectedIndex = this.items.length === 0 ? 0 : Math.max(0, this.selectedIndex - 1); return; }
				if (data === "\x1b[B" || data === "\x1bOB") { this.selectedIndex = this.items.length === 0 ? 0 : Math.min(this.items.length - 1, this.selectedIndex + 1); return; }
				if (data === "\r" || data === "\n") { const item = this.getSelectedItem(); if (item) this.onSelect?.(item); return; }
				if (data === "\x1b" || data === "\x1b\x1b") { this.onCancel?.(); }
			}
		},
		fuzzyFilter: <T,>(items: T[], query: string, getText: (item: T) => string): T[] => {
			if (!query) return [...items];
			const tokens = query.trim().split(/\s+/).filter(Boolean);
			if (tokens.length === 0) return [...items];
			const fuzzyMatch = (q: string, t: string) => {
				const ql = q.toLowerCase(); const tl = t.toLowerCase();
				let qi = 0; let score = 0;
				for (let ti = 0; ti < tl.length && qi < ql.length; ti++) { if (tl[ti] === ql[qi]) { score += ti; qi++; } }
				return { matches: qi === ql.length, score };
			};
			return items.map((item) => {
				const text = getText(item);
				let total = 0;
				for (const token of tokens) { const m = fuzzyMatch(token, text); if (!m.matches) return null; total += m.score; }
				return { item, total };
			}).filter((x): x is { item: T; total: number } => x !== null).sort((a,b)=>a.total-b.total).map((x)=>x.item);
		},
		truncateToWidth: (text: string, width: number, ellipsis = ""): string => {
			if (width <= 0) return "";
			if (text.length <= width) return text;
			const e = ellipsis.slice(0, width);
			return text.slice(0, Math.max(0, width - e.length)) + e;
		},
	};
	return { tui, keybindings, piTuiModule, piHostModule, renderCount: () => renders };
}

describe("prompt picker component", () => {
	const choices: readonly PromptChoice[] = [
		{ source: "sent", text: "alpha prompt" },
		{ source: "queued", text: "beta queued" },
		{ source: "sent", text: "gamma prompt" },
	];

	test("picker theme keeps its receiver so a this-dependent host theme works", async () => {
		// A theme whose selectedText reads `this`. The previous adapter extracted
		// theme.fg into a bare local, so `this` was undefined at call time and pi's
		// real Theme threw "Cannot read properties of undefined (reading 'tokenAnsi')".
		class ThisDependentTheme {
			private readonly token = "<accent>";
			selectedText(text: string): string {
				return `${this.token}${text}`;
			}
		}
		const theme = new ThisDependentTheme();
		const deps = {
			...makePickerDeps(),
			piHostModule: {
				getSelectListTheme: () => ({
					selectedPrefix: (text: string) => theme.selectedText(text),
					selectedText: (text: string) => theme.selectedText(text),
					description: (text: string) => text,
					scrollInfo: (text: string) => text,
					noMatch: (text: string) => text,
				}),
			},
		};
		const component = await createPromptPickerComponent(choices, () => {}, "", deps);
		const rendered = component.render(80).join("\n");
		expect(rendered).toContain("<accent>");
	});

	test("filter bar visible with current query", async () => {
		const component = await createPromptPickerComponent(choices, () => {}, "alp", makePickerDeps());
		const lines = component.render(80).join("\n");
		expect(lines).toContain("Filter:");
		expect(lines).toContain("alp");
	});

	test("empty filter shows all choices", async () => {
		let doneValue: PromptChoice | undefined | "unset" = "unset";
		const component = await createPromptPickerComponent(choices, (value) => {
			doneValue = value;
		}, "", makePickerDeps());
		const lines = component.render(80).join("\n");
		expect(lines).toContain("alpha prompt");
		expect(lines).toContain("beta queued");
		expect(lines).toContain("gamma prompt");
		expect(doneValue).toBe("unset");
	});

	test("typing narrows by case-insensitive substring match on prompt text", async () => {
		const component = await createPromptPickerComponent(choices, () => {}, "", makePickerDeps());
		component.handleInput?.("B");
		component.handleInput?.("E");
		component.handleInput?.("T");
		const lines = component.render(80).join("\n");
		expect(lines.toLowerCase()).toContain("beta queued");
		expect(lines.toLowerCase()).not.toContain("alpha prompt");
		expect(lines.toLowerCase()).not.toContain("gamma prompt");
	});

	test("fuzzy match: query that is subsequence but not contiguous substring finds expected choice", async () => {
		const component = await createPromptPickerComponent(choices, () => {}, "", makePickerDeps());
		component.handleInput?.("g");
		component.handleInput?.("p");
		component.handleInput?.("t");
		const lines = component.render(80).join("\n").toLowerCase();
		expect(lines).toContain("gamma prompt");
		expect(lines).not.toContain("alpha prompt");
		expect(lines).not.toContain("beta queued");
	});

	test("windowing: 30 choices renders at most fixed window, not 30 item lines", async () => {
		const many: PromptChoice[] = Array.from({ length: 30 }, (_, i) => ({
			source: i % 2 === 0 ? "sent" : "queued",
			text: `prompt number ${String(i).padStart(2, "0")}`,
		}));
		const component = await createPromptPickerComponent(many, () => {}, "", makePickerDeps());
		const lines = component.render(80);
		expect(lines.length).toBeLessThanOrEqual(14);
		for (let i = 10; i < 30; i++) {
			expect(lines.join("\n")).not.toContain(`prompt number ${String(i).padStart(2, "0")}`);
		}
		for (let i = 0; i < 20; i++) {
			component.handleInput?.("\x1b[B");
		}
		const moved = component.render(80).join("\n");
		expect(moved).toContain("prompt number 20");
		expect(moved.toLowerCase()).toMatch(/\d+\/30|scroll|↑|↓|more/);
	});

	test("backspace restores previous filtered results", async () => {
		const component = await createPromptPickerComponent(choices, () => {}, "", makePickerDeps());
		component.handleInput?.("b");
		component.handleInput?.("e");
		component.handleInput?.("t");
		component.handleInput?.("\x7f");
		component.handleInput?.("\x7f");
		component.handleInput?.("\x7f");
		const lines = component.render(80).join("\n");
		expect(lines).toContain("alpha prompt");
		expect(lines).toContain("beta queued");
		expect(lines).toContain("gamma prompt");
	});

	test("up/down moves selection and clamps to filtered bounds", async () => {
		const selected: Array<PromptChoice | undefined> = [];
		const component = await createPromptPickerComponent(choices, (value) => {
			selected.push(value);
		}, "", makePickerDeps());
		component.handleInput?.("\x1b[A");
		component.handleInput?.("\r");
		expect(selected).toEqual([choices[0]]);
	});

	test("enter returns selected PromptChoice", async () => {
		const selected: Array<PromptChoice | undefined> = [];
		const component = await createPromptPickerComponent(choices, (value) => {
			selected.push(value);
		}, "", makePickerDeps());
		component.handleInput?.("\x1b[B");
		component.handleInput?.("\r");
		expect(selected).toEqual([choices[1]]);
	});

	test("escape cancels", async () => {
		const selected: Array<PromptChoice | undefined | "unset"> = ["unset"];
		const component = await createPromptPickerComponent(choices, (value) => {
			selected.push(value);
		}, "", makePickerDeps());
		component.handleInput?.("\x1b");
		expect(selected).toEqual(["unset", undefined]);
	});

	test("ctrl+c cancels when keybindings match tui.select.cancel", async () => {
		const selected: Array<PromptChoice | undefined | "unset"> = ["unset"];
		const component = await createPromptPickerComponent(choices, (value) => {
			selected.push(value);
		}, "", makePickerDeps());
		component.handleInput?.("\x03");
		expect(selected).toEqual(["unset", undefined]);
	});

	test("requestRender called after input", async () => {
		const deps = makePickerDeps();
		const component = await createPromptPickerComponent(choices, () => {}, "", deps);
		const before = deps.renderCount();
		component.handleInput?.("a");
		expect(deps.renderCount()).toBeGreaterThan(before);
	});

	test("pre-filter seed: initialQuery shows it and filters", async () => {
		const component = await createPromptPickerComponent(choices, () => {}, "beta", makePickerDeps());
		const lines = component.render(80).join("\n");
		expect(lines).toContain("beta");
		expect(lines.toLowerCase()).toContain("beta queued");
		expect(lines.toLowerCase()).not.toContain("alpha prompt");
	});

	test("no-match shows message and enter does not select", async () => {
		const selected: Array<PromptChoice | undefined> = [];
		const component = await createPromptPickerComponent(choices, (value) => {
			selected.push(value);
		}, "", makePickerDeps());
		for (const char of "zzz") {
			component.handleInput?.(char);
		}
		const lines = component.render(80).join("\n").toLowerCase();
		expect(lines).toContain("no match");
		component.handleInput?.("\r");
		expect(selected).toEqual([]);
	});

	test("renders long or multiline prompt as a single preview line", async () => {
		const longMultiline: readonly PromptChoice[] = [
			{
				source: "sent",
				text: "line one\nline two\nline three with extra words to make it long enough for preview behavior",
			},
		];
		const component = await createPromptPickerComponent(longMultiline, () => {}, "", makePickerDeps());
		const lines = component.render(120);
		const choiceLines = lines.filter((line) => line.includes("Sent:"));
		expect(choiceLines).toHaveLength(1);
		expect(choiceLines[0]).toContain(`Sent: ${promptPreview(longMultiline[0].text)}`);
		expect(choiceLines[0]).not.toContain("\n");
	});
});

describe("pick mode uses custom picker when available", () => {
	test("pickPromptChoice uses ui.custom and does not call select", async () => {
		const choices: readonly PromptChoice[] = [
			{ source: "sent", text: "sent prompt" },
			{ source: "queued", text: "queued prompt" },
		];
		let selectCalls = 0;
		let customCalls = 0;
		const ui = {
			select: async () => {
				selectCalls += 1;
				return undefined;
			},
			custom: async <T>(factory: (tui: unknown, theme: unknown, kb: unknown, done: (value: T) => void) => unknown) => {
				customCalls += 1;
				const component = await factory(
					{},
					{},
					{},
					(value: T) => value,
				);
				const c = component as { handleInput?: (data: string) => void };
				c.handleInput?.("\r");
				return choices[0] as T;
			},
		};
		const result = await pickPromptChoice(choices, "", ui as never);
		expect(customCalls).toBe(1);
		expect(selectCalls).toBe(0);
		expect(result).toEqual(choices[0]);
	});

	test("resolvePromptChoice pick uses ui.custom and does not show separate filter dialog", async () => {
		let selectCalls = 0;
		let inputCalls = 0;
		let customCalls = 0;
		const ui = {
			select: async () => {
				selectCalls += 1;
				return undefined;
			},
			input: async () => {
				inputCalls += 1;
				return "";
			},
			custom: async <T>(factory: (tui: unknown, theme: unknown, kb: unknown, done: (value: T) => void) => unknown) => {
				customCalls += 1;
				const component = await factory({}, {}, {}, (value: T) => value);
				const c = component as { handleInput?: (data: string) => void };
				c.handleInput?.("\x1b[B");
				c.handleInput?.("\r");
				return { source: "queued", text: "queued prompt" } as T;
			},
		};
		const ctx = {
			sessionManager: {
				getBranch: () => [{ type: "message", message: { role: "user", content: "sent prompt" } }],
			},
			ui,
		};
		const result = await resolvePromptChoice("pick", ctx as never, { readQueuedPrompt: () => "queued prompt" });
		expect(customCalls).toBe(1);
		expect(selectCalls).toBe(0);
		expect(inputCalls).toBe(0);
		expect(result).toEqual({ source: "queued", text: "queued prompt" });
	});

	test("ui.custom unavailable falls back to select", async () => {
		const { ctx, selectCalls } = makeContext({
			branch: [{ type: "message", message: { role: "user", content: "sent prompt" } }],
			selectResult: `Sent: ${promptPreview("sent prompt")}`,
		});
		const result = await resolvePromptChoice("pick", ctx as never, { readQueuedPrompt: () => "queued prompt" });
		expect(selectCalls).toHaveLength(1);
		expect(result).toEqual({ source: "sent", text: "sent prompt" });
	});
});
