import { describe, expect, test } from "bun:test";
import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import promptTools, {
	EMPTY_SESSION_MESSAGE,
	NOTHING_TO_CONTINUE_MESSAGE,
	NOTHING_TO_COPY_QUEUED_MESSAGE,
	NOTHING_TO_REPEAT_QUEUED_MESSAGE,
	copyTextToClipboard,
	createPromptToolsExtension,
	extractUserMessageText,
	findLastSentUserPrompt,
	handleContinue,
	handleCopyUserPrompt,
	handleRepeatUserPrompt,
	nucleusUserRoot,
	parsePromptSourceArg,
	piQueuedCommandsDir,
	pickPromptChoice,
	promptPreview,
	readQueuedPrompt,
	resolvePromptChoice,
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

	test("returns single available choice without prompting", async () => {
		const { ctx, selectCalls } = makeContext();
		const result = await pickPromptChoice(
			{ source: "sent", text: "only sent" },
			null,
			(ctx as { ui: { select: (title: string, options: string[]) => Promise<string | undefined> } }).ui as never,
		);
		expect(selectCalls).toEqual([]);
		expect(result).toEqual({ source: "sent", text: "only sent" });
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

	test("warns when agent is busy", async () => {
		const { commands, sentMessages } = registerExtension();
		const { ctx, notifications } = makeContext({
			branch: [{ type: "message", message: { role: "user", content: "hello" } }],
			idle: false,
		});
		await commands.continueCommand?.handler("", ctx);
		expect(sentMessages).toEqual([]);
		expect(notifications).toEqual([["Agent is busy.", "warning"]]);
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
