/**
 * Routes deletion-shaped bash tool calls through the shared harness filter so the
 * deletion policy lives in `src/scripts/notify/filters/safe-delete.ts`, not here.
 * This extension only pre-filters on deletion words, forwards the hook payload to
 * `harness-filter pi`, and turns the verdict into a block, a confirmation prompt,
 * or an allow. It must not classify commands locally.
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { spawn } from "node:child_process";

// A cheap routing predicate: the command must mention a deletion word before the
// runner is consulted. It never decides, so it stays permissive and leaves the
// CLI-subcommand cases (`git rm`, `brew rm`, and friends) to the shared policy.
const DELETION_WORD_RE = /\b(?:rm|del|rd|rmdir|erase|ri|unlink|shred|remove-item)\b/i;

export const DEFAULT_RUNNER_COMMAND = "harness-filter";
export const DEFAULT_TIMEOUT_MS = 10_000;
const STATUS_KEY = "safe-delete";

export interface SpawnResult {
	readonly code: number | null;
	readonly signal: NodeJS.Signals | null;
	readonly stdout: string;
	readonly stderr: string;
	readonly timedOut: boolean;
	readonly error?: string;
}

export type SpawnFn = (
	command: string,
	args: readonly string[],
	stdin: string,
	timeoutMs: number,
) => Promise<SpawnResult>;

export interface RunnerOptions {
	readonly runnerCommand?: string;
	readonly runnerArgs?: readonly string[];
	readonly timeoutMs?: number;
	readonly spawnFn?: SpawnFn;
}

export interface Verdict {
	readonly decision: "allow" | "ask" | "deny";
	readonly raw: string;
	readonly stderr: string;
}

function collectStream(stream: NodeJS.ReadableStream | null): Promise<string> {
	if (stream === null) {
		return Promise.resolve("");
	}
	return new Promise((resolve) => {
		let text = "";
		stream.setEncoding("utf8");
		stream.on("data", (chunk: string) => {
			text += chunk;
		});
		stream.on("end", () => {
			resolve(text);
		});
		stream.on("error", () => {
			resolve(text);
		});
	});
}

export const spawnHarnessFilter: SpawnFn = async (command, args, stdin, timeoutMs) => {
	return await new Promise<SpawnResult>((resolve) => {
		let settled = false;
		let timedOut = false;
		let timer: ReturnType<typeof setTimeout> | undefined;
		const child = spawn(command, [...args], { stdio: ["pipe", "pipe", "pipe"] });
		const stdoutPromise = collectStream(child.stdout);
		const stderrPromise = collectStream(child.stderr);

		const finish = async (base: Omit<SpawnResult, "stdout" | "stderr">): Promise<void> => {
			if (settled) {
				return;
			}
			settled = true;
			if (timer !== undefined) {
				clearTimeout(timer);
			}
			const [stdout, stderr] = await Promise.all([stdoutPromise, stderrPromise]);
			resolve({ ...base, stdout, stderr });
		};

		child.on("error", (error: Error) => {
			void finish({ code: null, signal: null, timedOut, error: error.message });
		});
		child.on("close", (code, signal) => {
			void finish({ code, signal, timedOut });
		});

		if (timeoutMs > 0) {
			timer = setTimeout(() => {
				timedOut = true;
				child.kill("SIGKILL");
			}, timeoutMs);
		}

		child.stdin.on("error", () => {
			// The child may exit before consuming stdin; stdout/stderr and close
			// still determine the verdict.
		});
		child.stdin.end(stdin);
	});
};

function parseVerdict(stdout: string): "allow" | "ask" | "deny" | null {
	const line = stdout.trim().split("\n").pop()?.trim() ?? "";
	if (line === "allow" || line === "ask" || line === "deny") {
		return line;
	}
	return null;
}

export function hasDeletionWord(command: string): boolean {
	return DELETION_WORD_RE.test(command);
}

export function buildPayload(command: string): string {
	return JSON.stringify({ tool_name: "bash", tool_input: { command } });
}

export async function runHarnessFilter(
	command: string,
	options: RunnerOptions = {},
): Promise<Verdict> {
	const runnerCommand = options.runnerCommand ?? DEFAULT_RUNNER_COMMAND;
	const runnerArgs = options.runnerArgs ?? ["pi"];
	const timeoutMs = options.timeoutMs ?? DEFAULT_TIMEOUT_MS;
	const spawnFn = options.spawnFn ?? spawnHarnessFilter;
	const result = await spawnFn(runnerCommand, runnerArgs, buildPayload(command), timeoutMs);

	const decision = parseVerdict(result.stdout);
	if (decision !== null) {
		return { decision, raw: result.stdout.trim(), stderr: result.stderr.trim() };
	}

	const details = [
		result.error ? `error: ${result.error}` : null,
		result.timedOut ? "timed out" : null,
		result.code !== null ? `exit: ${String(result.code)}` : null,
		result.signal !== null ? `signal: ${result.signal}` : null,
	]
		.filter((part): part is string => part !== null)
		.join(", ");
	const stderr = result.stderr.trim();
	const suffix = details.length > 0 ? ` (${details})` : "";
	return {
		decision: "ask",
		raw: stderr.length > 0 ? stderr : `no verdict${suffix}`,
		stderr,
	};
}

export interface SafeDeleteUi {
	hasUI: boolean;
	select?(message: string, options: string[]): Promise<string | undefined>;
	confirm?(title: string, message: string): Promise<boolean>;
	setStatus?(key: string, value: string | undefined): void;
}

function setStatus(ui: SafeDeleteUi, value: string | undefined): void {
	if (typeof ui.setStatus === "function") {
		ui.setStatus(STATUS_KEY, value);
	}
}


function verdictDetail(verdict: Verdict): string {
	const parts = verdict.raw.split("\t");
	if (parts.length >= 3) {
		const detail = parts.slice(2).join("\t").trim();
		if (detail.length > 0) {
			return `${parts[1]}: ${detail}`;
		}
	}
	const stderr = verdict.stderr.trim();
	if (stderr.length > 0) {
		return stderr;
	}
	if (parts.length >= 2 && parts[1]?.trim().length > 0) {
		return parts[1]!.trim();
	}
	return "";
}

function block(reason: string): { block: true; reason: string } {
	return { block: true, reason };
}

export function createSafeDeleteExtension(options: RunnerOptions = {}): (pi: ExtensionAPI) => void {
	return function (pi: ExtensionAPI): void {
		pi.on("tool_call", async (event, ctx) => {
			if (event.toolName !== "bash") {
				return undefined;
			}

			const command = event.input.command;
			if (typeof command !== "string" || !hasDeletionWord(command)) {
				return undefined;
			}

			const verdict = await runHarnessFilter(command, options);
			const ui = ctx.ui as SafeDeleteUi;

			if (verdict.decision === "allow") {
				return undefined;
			}

			if (verdict.decision === "deny") {
				setStatus(ui, "safe-delete: blocked");
				try {
					const detail = verdictDetail(verdict);
					return block(detail.length > 0
						? `Blocked by the safe-delete filter (deny). ${detail} Use shell-safe-rm or rip2 instead.`
						: "Blocked by the safe-delete filter (deny). Use shell-safe-rm or rip2 instead.");
				} finally {
					setStatus(ui, undefined);
				}
			}

			setStatus(ui, "safe-delete: confirmation required");
			try {
				if (!ctx.hasUI) {
					const detail = verdictDetail(verdict);
					return block(detail.length > 0
						? `Blocked by the safe-delete filter (ask) and no confirmation UI is available. ${detail} Use shell-safe-rm or rip2 instead.`
						: "Blocked by the safe-delete filter (ask) and no confirmation UI is available. Use shell-safe-rm or rip2 instead.");
				}
				if (typeof ui.confirm === "function") {
					const detail = verdictDetail(verdict);
					const message = detail.length > 0
						? `Allow this command?\n\n${command}\n\nFilter: ${detail}`
						: `Allow this command?\n\n${command}`;
					const approved = await ui.confirm(
						"Safe-delete filter requires confirmation",
						message,
					);
					return approved ? undefined : block("Blocked by safe-delete extension");
				}
				if (typeof ui.select === "function") {
					const detail = verdictDetail(verdict);
					const message = detail.length > 0
						? `Safe-delete filter requires confirmation:\n\n  ${command}\n\nFilter: ${detail}\n\nAllow?`
						: `Safe-delete filter requires confirmation:\n\n  ${command}\n\nAllow?`;
					const choice = await ui.select(message, ["Allow", "Block"]);
					return choice === "Allow" ? undefined : block("Blocked by safe-delete extension");
				}
				const detail = verdictDetail(verdict);
				return block(detail.length > 0
					? `Blocked by the safe-delete filter (ask) and no confirmation UI is available. ${detail} Use shell-safe-rm or rip2 instead.`
					: "Blocked by the safe-delete filter (ask) and no confirmation UI is available. Use shell-safe-rm or rip2 instead.");
			} finally {
				setStatus(ui, undefined);
			}
		});
	};
}

export default createSafeDeleteExtension();
