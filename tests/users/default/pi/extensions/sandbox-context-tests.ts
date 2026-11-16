import { describe, expect, test } from "bun:test";
import {
	SANDBOXED_CONTEXT_BLOCK,
	UNSANDBOXED_CONTEXT_BLOCK,
	buildSandboxContextBlock,
	createSandboxContextExtension,
	messageContainsSandboxContext,
} from "../../../../../src/users/default/pi/extensions/sandbox-context.ts";

type Handler = (event?: unknown, ctx?: unknown) => unknown | Promise<unknown>;

interface Registered {
	readonly events: Record<string, Handler>;
}

function registerExtension(env: NodeJS.ProcessEnv = {}): Registered {
	const events: Record<string, Handler> = {};
	const pi = {
		on: (name: string, handler: Handler) => {
			events[name] = handler;
			return () => {};
		},
		registerCommand: () => {},
	};
	createSandboxContextExtension({ env })(pi as never);
	return { events };
}

function contextEvent(messages: unknown[] = []): { messages: unknown[] } {
	return { messages };
}

function textOfFirstInjected(result: unknown): string {
	const messages = (result as { messages?: unknown[] } | undefined)?.messages ?? [];
	const first = messages[0] as { content?: Array<{ text?: string }> } | undefined;
	return first?.content?.[0]?.text ?? "";
}

describe("buildSandboxContextBlock", () => {
	test("returns sandboxed block when SANDBOX_RUNTIME is sandboxed", () => {
		expect(buildSandboxContextBlock({ SANDBOX_RUNTIME: "1" })).toBe(SANDBOXED_CONTEXT_BLOCK);
		expect(buildSandboxContextBlock({ SANDBOX_RUNTIME: "srt" })).toBe(SANDBOXED_CONTEXT_BLOCK);
	});

	test("returns unsandboxed block when SANDBOX_RUNTIME indicates unsandboxed", () => {
		expect(buildSandboxContextBlock({})).toBe(UNSANDBOXED_CONTEXT_BLOCK);
		expect(buildSandboxContextBlock({ SANDBOX_RUNTIME: "" })).toBe(UNSANDBOXED_CONTEXT_BLOCK);
		expect(buildSandboxContextBlock({ SANDBOX_RUNTIME: "0" })).toBe(UNSANDBOXED_CONTEXT_BLOCK);
		expect(buildSandboxContextBlock({ SANDBOX_RUNTIME: "false" })).toBe(UNSANDBOXED_CONTEXT_BLOCK);
	});
});

describe("sandbox context injection lifecycle", () => {
	test("injects sandboxed block once on session start before first response", async () => {
		const { events } = registerExtension({ SANDBOX_RUNTIME: "1" });
		await events.session_start?.();
		const result = await events.context?.(contextEvent([]));
		expect(textOfFirstInjected(result)).toBe(SANDBOXED_CONTEXT_BLOCK);
	});

	test("injects unsandboxed block once on session start before first response", async () => {
		const { events } = registerExtension({});
		await events.session_start?.();
		const result = await events.context?.(contextEvent([]));
		expect(textOfFirstInjected(result)).toBe(UNSANDBOXED_CONTEXT_BLOCK);
	});

	test("does not inject on second turn after agent_end", async () => {
		const { events } = registerExtension({ SANDBOX_RUNTIME: "1" });
		await events.session_start?.();
		const first = await events.context?.(contextEvent([]));
		expect(textOfFirstInjected(first)).toBe(SANDBOXED_CONTEXT_BLOCK);
		await events.agent_end?.();
		const second = await events.context?.(contextEvent((first as { messages: unknown[] }).messages));
		expect(second).toBeUndefined();
	});

	test("re-injects after compaction with wording matching SANDBOX_RUNTIME", async () => {
		const { events } = registerExtension({ SANDBOX_RUNTIME: "1" });
		await events.session_start?.();
		await events.context?.(contextEvent([]));
		await events.agent_end?.();
		await events.session_compact?.();
		const afterCompact = await events.context?.(contextEvent([]));
		expect(textOfFirstInjected(afterCompact)).toBe(SANDBOXED_CONTEXT_BLOCK);
		await events.agent_end?.();
		const later = await events.context?.(contextEvent([]));
		expect(later).toBeUndefined();
	});

	test("re-injects unsandboxed block after compaction when unsandboxed", async () => {
		const { events } = registerExtension({ SANDBOX_RUNTIME: "" });
		await events.session_start?.();
		await events.context?.(contextEvent([]));
		await events.agent_end?.();
		await events.session_compact?.();
		const afterCompact = await events.context?.(contextEvent([]));
		expect(textOfFirstInjected(afterCompact)).toBe(UNSANDBOXED_CONTEXT_BLOCK);
	});

	test("inserts after compaction summaries", async () => {
		const { events } = registerExtension({ SANDBOX_RUNTIME: "1" });
		await events.session_start?.();
		const summary = { role: "compactionSummary", content: "summary" };
		const result = (await events.context?.(contextEvent([summary]))) as { messages: unknown[] } | undefined;
		expect(result?.messages[0]).toBe(summary);
		expect(textOfFirstInjected({ messages: result?.messages.slice(1) })).toBe(SANDBOXED_CONTEXT_BLOCK);
	});

	test("does not duplicate when context already contains sandbox block", async () => {
		const { events } = registerExtension({ SANDBOX_RUNTIME: "1" });
		await events.session_start?.();
		const existing = {
			role: "user",
			content: [{ type: "text", text: SANDBOXED_CONTEXT_BLOCK }],
		};
		const result = await events.context?.(contextEvent([existing]));
		expect(result).toBeUndefined();
	});
});

describe("messageContainsSandboxContext", () => {
	test("detects sandboxed and unsandboxed block text", () => {
		expect(
			messageContainsSandboxContext([{ role: "user", content: [{ type: "text", text: SANDBOXED_CONTEXT_BLOCK }] }]),
		).toBe(true);
		expect(
			messageContainsSandboxContext([{ role: "user", content: [{ type: "text", text: UNSANDBOXED_CONTEXT_BLOCK }] }]),
		).toBe(true);
		expect(messageContainsSandboxContext([{ role: "user", content: [{ type: "text", text: "other" }] }])).toBe(false);
	});
});
