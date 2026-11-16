/**
 * Injects a model-visible sandbox context block at session start and after
 * compaction. The block states whether the session is sandboxed and what that
 * means for the agent. It is inserted once per start/compact cycle and never
 * repeated on later turns in the same cycle.
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { detectSandbox } from "./sandbox-indicator.ts";

export const SANDBOX_CONTEXT_MARKER = "pi:sandbox-context";

export const SANDBOXED_CONTEXT_BLOCK =
	"You are inside the srt sandbox. The repo and the granted scratch paths work normally, but the fence is real: network destinations and Unix sockets are allowlisted, some paths are read-only, git config hooks and secrets are protected, and deletions land in the Trash through the safe wrapper (Finder 'Put Back' is unavailable because Apple Events are denied). If a command fails with a permission or socket error, assume the fence before assuming a bug, say what you need, and use `pi-unrestricted` only when the task genuinely needs the unsandboxed host.";

export const UNSANDBOXED_CONTEXT_BLOCK =
	"You are outside the srt sandbox, so the full host is reachable. That is more power than the sandboxed default, so treat deletions, secrets, and network calls with extra care; the safe-delete rules still apply, and a command that worked here may be blocked in the sandbox when you switch back.";

export function buildSandboxContextBlock(env: NodeJS.ProcessEnv = process.env): string {
	return detectSandbox(env).sandboxed ? SANDBOXED_CONTEXT_BLOCK : UNSANDBOXED_CONTEXT_BLOCK;
}

export function createSandboxContextExtension(
	deps: { readonly env?: NodeJS.ProcessEnv } = {},
): (pi: ExtensionAPI) => void {
	const env = deps.env ?? process.env;
	return function (pi: ExtensionAPI): void {
		let injectContext = true;

		pi.on("session_start", async () => {
			injectContext = true;
		});

		pi.on("session_compact", async () => {
			injectContext = true;
		});

		pi.on("agent_end", async () => {
			injectContext = false;
		});

		pi.on("context", async (event) => {
			if (!injectContext) return;
			if (messageContainsSandboxContext(event.messages)) return;

			const block = buildSandboxContextBlock(env);
			const contextMessage = {
				role: "user" as const,
				content: [{ type: "text" as const, text: block }],
				timestamp: Date.now(),
			};

			const insertAt = firstNonCompactionSummaryIndex(event.messages);
			return {
				messages: [...event.messages.slice(0, insertAt), contextMessage, ...event.messages.slice(insertAt)],
			};
		});
	};
}

export function messageContainsSandboxContext(messages: unknown[]): boolean {
	return messages.some((message) => {
		const content = (message as { content?: unknown }).content;
		if (typeof content === "string") return content.includes(SANDBOX_CONTEXT_MARKER) || isSandboxContextText(content);
		if (!Array.isArray(content)) return false;
		return content.some((part) => {
			if (!part || typeof part !== "object") return false;
			const text = (part as { type?: unknown; text?: unknown }).text;
			if ((part as { type?: unknown }).type !== "text" || typeof text !== "string") return false;
			return text.includes(SANDBOX_CONTEXT_MARKER) || isSandboxContextText(text);
		});
	});
}

function isSandboxContextText(text: string): boolean {
	return text === SANDBOXED_CONTEXT_BLOCK || text === UNSANDBOXED_CONTEXT_BLOCK;
}

function firstNonCompactionSummaryIndex(messages: unknown[]): number {
	let index = 0;
	while ((messages[index] as { role?: unknown } | undefined)?.role === "compactionSummary") {
		index += 1;
	}
	return index;
}

export default createSandboxContextExtension();
