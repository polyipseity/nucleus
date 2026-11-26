import { describe, expect, test } from "bun:test";
import {
	createSandboxContextExtension,
	firstNonCompactionSummaryIndex,
	isUserMessage,
	lastMessageIsUser,
	type SandboxContextExecResult,
} from "../../../../../src/users/default/pi/extensions/sandbox-context.ts";

type Handler = (event?: unknown, ctx?: unknown) => unknown | Promise<unknown>;

interface Registered {
	readonly events: Record<string, Handler>;
	readonly calls: Array<{ command: string; args: string[] }>;
}

function registerExtension(
	exec: (command: string, args: readonly string[], options: { readonly timeout: number }) => Promise<SandboxContextExecResult> | SandboxContextExecResult,
	deps: { harness?: string; sessionId?: string } = {},
): Registered {
	const events: Record<string, Handler> = {};
	const calls: Array<{ command: string; args: string[] }> = [];
	const pi = {
		on: (name: string, handler: Handler) => {
			events[name] = handler;
			return () => {};
		},
		registerCommand: () => {},
		exec: async () => ({ stdout: "", stderr: "", code: 0 }),
	};
	const wrappedExec = async (command: string, args: readonly string[], options: { readonly timeout: number }) => {
		calls.push({ command, args: [...args] });
		return await exec(command, args, options);
	};
	createSandboxContextExtension({ exec: wrappedExec, ...deps })(pi as never);
	return { events, calls };
}

function userMessage(text = "hello"): { role: "user"; content: Array<{ type: "text"; text: string }> } {
	return { role: "user", content: [{ type: "text", text }] };
}

function assistantMessage(text = "hi"): { role: "assistant"; content: Array<{ type: "text"; text: string }> } {
	return { role: "assistant", content: [{ type: "text", text }] };
}

function contextEvent(messages: unknown[]): { messages: unknown[] } {
	return { messages };
}

function insertedText(result: unknown): string {
	const messages = (result as { messages?: unknown[] } | undefined)?.messages ?? [];
	const first = messages[0] as { content?: Array<{ text?: string }> } | undefined;
	return first?.content?.[0]?.text ?? "";
}

describe("sandbox context user-message detection", () => {
	test("detects a user message as the last context message", () => {
		expect(isUserMessage(userMessage())).toBe(true);
		expect(isUserMessage(assistantMessage())).toBe(false);
		expect(lastMessageIsUser([assistantMessage(), userMessage()])).toBe(true);
		expect(lastMessageIsUser([userMessage(), assistantMessage()])).toBe(false);
		expect(lastMessageIsUser([])).toBe(false);
	});

	test("finds insertion point after leading compaction summaries", () => {
		expect(
			firstNonCompactionSummaryIndex([
				{ role: "compactionSummary", content: "a" },
				{ role: "compactionSummary", content: "b" },
				userMessage(),
			]),
		).toBe(2);
	});
});

describe("sandbox context CLI-driven injection", () => {
	test("inserts returned text when the last message is a user message", async () => {
		const block = "You are inside the srt sandbox.";
		const { events, calls } = registerExtension(async () => ({ stdout: block, stderr: "", code: 0 }));
		const result = await events.context?.(contextEvent([userMessage("run tests")]));
		expect(calls).toHaveLength(1);
		expect(calls[0]?.command).toBe("nucleus-utils");
		expect(calls[0]?.args).toEqual([
			"harness",
			"report-sandbox",
			"pi",
			"--format",
			"text",
			"--session-id",
			"default",
		]);
		expect(insertedText(result)).toBe(block);
	});

	test("does not insert when the CLI returns no text", async () => {
		const { events, calls } = registerExtension(async () => ({ stdout: "", stderr: "", code: 0 }));
		const result = await events.context?.(contextEvent([userMessage("run tests")]));
		expect(calls).toHaveLength(1);
		expect(result).toBeUndefined();
	});

	test("does not call the CLI or insert when the last message is not a user message", async () => {
		let called = 0;
		const { events } = registerExtension(async () => {
			called += 1;
			return { stdout: "block", stderr: "", code: 0 };
		});
		const result = await events.context?.(contextEvent([userMessage("hi"), assistantMessage("hello")]));
		expect(called).toBe(0);
		expect(result).toBeUndefined();
	});

	test("inserts after compaction summaries when the CLI returns context", async () => {
		const block = "You are outside the srt sandbox.";
		const summary = { role: "compactionSummary", content: "summary" };
		const { events } = registerExtension(async () => ({ stdout: block, stderr: "", code: 0 }));
		const result = (await events.context?.(contextEvent([summary, userMessage("continue")]))) as
			| { messages: unknown[] }
			| undefined;
		expect(result?.messages[0]).toBe(summary);
		expect(insertedText({ messages: result?.messages.slice(1) })).toBe(block);
		expect(result?.messages[result.messages.length - 1]).toEqual(userMessage("continue"));
	});

	test("inserts a change notice for a resumed session that differs from its recorded state", async () => {
		const notice =
			"Sandbox state changed: sandboxed -> unsandboxed. You are outside the srt sandbox, so the full host is reachable.";
		const outputs = [
			{ stdout: "You are inside the srt sandbox.", stderr: "", code: 0 },
			{ stdout: "", stderr: "", code: 0 },
			{ stdout: notice, stderr: "", code: 0 },
		];
		let index = 0;
		const { events, calls } = registerExtension(async () => outputs[Math.min(index++, outputs.length - 1)]!);

		const first = await events.context?.(contextEvent([userMessage("first turn")]));
		expect(insertedText(first)).toContain("inside the srt sandbox");

		const unchanged = await events.context?.(contextEvent([userMessage("second turn")]));
		expect(unchanged).toBeUndefined();

		const resumed = await events.context?.(contextEvent([userMessage("resumed turn")]));
		expect(insertedText(resumed)).toBe(notice);
		expect(calls).toHaveLength(3);
	});

	test("ignores CLI failures and non-zero exits", async () => {
		const failing = registerExtension(async () => ({ stdout: "block", stderr: "err", code: 1 }));
		await expect(failing.events.context?.(contextEvent([userMessage("x")]))).resolves.toBeUndefined();

		let threw = 0;
		const throwing = registerExtension(async () => {
			threw += 1;
			throw new Error("exec failed");
		});
		await expect(throwing.events.context?.(contextEvent([userMessage("x")]))).resolves.toBeUndefined();
		expect(threw).toBe(1);
	});

	test("passes a custom harness and session id to the CLI", async () => {
		const { events, calls } = registerExtension(
			async () => ({ stdout: "", stderr: "", code: 0 }),
			{ harness: "pi", sessionId: "session-42" },
		);
		await events.context?.(contextEvent([userMessage("hello")]));
		expect(calls[0]?.args).toEqual([
			"harness",
			"report-sandbox",
			"pi",
			"--format",
			"text",
			"--session-id",
			"session-42",
		]);
	});
});
