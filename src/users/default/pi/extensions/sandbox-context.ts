/**
 * Calls `nucleus-utils harness report-sandbox` on every context event whose last
 * message is a user message and inserts the returned text. The command owns the
 * record, the decision, and the emitted context, so this extension does not
 * select the block itself.
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

const SANDBOX_CONTEXT_COMMAND = "nucleus-utils";
const SANDBOX_CONTEXT_TIMEOUT_MS = 10_000;

export interface SandboxContextExecResult {
	readonly stdout?: string;
	readonly stderr?: string;
	readonly code?: number | null;
}

export interface SandboxContextDependencies {
	readonly exec?: (
		command: string,
		args: readonly string[],
		options: { readonly timeout: number },
	) => Promise<SandboxContextExecResult> | SandboxContextExecResult;
	readonly harness?: string;
	readonly sessionId?: string;
}

export function isUserMessage(message: unknown): boolean {
	if (typeof message !== "object" || message === null) {
		return false;
	}
	return (message as { role?: unknown }).role === "user";
}

export function lastMessageIsUser(messages: unknown[]): boolean {
	if (!Array.isArray(messages) || messages.length === 0) {
		return false;
	}
	return isUserMessage(messages[messages.length - 1]);
}

export function firstNonCompactionSummaryIndex(messages: unknown[]): number {
	let index = 0;
	while ((messages[index] as { role?: unknown } | undefined)?.role === "compactionSummary") {
		index += 1;
	}
	return index;
}

function textOfExecResult(result: SandboxContextExecResult): string {
	if (typeof result.code === "number" && result.code !== 0) {
		return "";
	}
	return typeof result.stdout === "string" ? result.stdout : "";
}

export function createSandboxContextExtension(
	deps: SandboxContextDependencies = {},
): (pi: ExtensionAPI) => void {
	const harness = deps.harness ?? "pi";
	const sessionId = deps.sessionId ?? "default";
	return function (pi: ExtensionAPI): void {
		pi.on("context", async (event) => {
			const messages = Array.isArray((event as { messages?: unknown }).messages)
				? ((event as { messages: unknown[] }).messages)
				: [];
			if (!lastMessageIsUser(messages)) {
				return;
			}

			let result: SandboxContextExecResult;
			try {
				const exec = deps.exec ?? ((command, args, options) => pi.exec(command, [...args], options));
				result = await exec(
					SANDBOX_CONTEXT_COMMAND,
					["harness", "report-sandbox", harness, "--format", "text", "--session-id", sessionId],
					{ timeout: SANDBOX_CONTEXT_TIMEOUT_MS },
				);
			} catch {
				return;
			}

			const text = textOfExecResult(result);
			if (text.trim().length === 0) {
				return;
			}

			const contextMessage = {
				role: "user" as const,
				content: [{ type: "text" as const, text }],
				timestamp: Date.now(),
			};
			const insertAt = firstNonCompactionSummaryIndex(messages);
			return {
				messages: [...messages.slice(0, insertAt), contextMessage, ...messages.slice(insertAt)],
			};
		});
	};
}

export default createSandboxContextExtension();
