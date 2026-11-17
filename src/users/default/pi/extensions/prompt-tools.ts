/**
 * Pi prompt tools: /continue, /copy-user-prompt, /repeat-user-prompt.
 *
 * Semantics are shared: `sent` is the last user-role message actually sent to
 * the model, `queued` is the last queued harness-bridge prompt for pi, and
 * `pick` selects between them with the last sent message highlighted by
 * default. Copy uses clipboard exec with a selectable-text fallback, repeat
 * resubmits as a new user turn and confirms while streaming, and continue
 * retries or continues the turn.
 */

import type { ExtensionAPI, ExtensionCommandContext } from "@earendil-works/pi-coding-agent";
import { spawn } from "node:child_process";
import { readdirSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

export const EMPTY_SESSION_MESSAGE = "Nothing to repeat yet \u2014 this session has no user message.";
export const NOTHING_TO_COPY_QUEUED_MESSAGE = "Nothing to copy yet \u2014 no queued prompt.";
export const NOTHING_TO_REPEAT_QUEUED_MESSAGE = "Nothing to repeat yet \u2014 no queued prompt.";
export const NOTHING_TO_CONTINUE_MESSAGE = EMPTY_SESSION_MESSAGE;

export type PromptSource = "sent" | "queued";

export interface PromptChoice {
	readonly source: PromptSource;
	readonly text: string;
}

export interface PromptToolsDeps {
	readonly env?: NodeJS.ProcessEnv;
	readonly platform?: NodeJS.Platform;
	readonly homeDir?: () => string;
	readonly readQueuedPrompt?: (commandsDir: string) => string | null;
	readonly copyToClipboard?: (text: string) => Promise<boolean>;
	readonly writeToCommandStdin?: (command: string, args: readonly string[], text: string) => Promise<boolean>;
}

/**
 * Nucleus USER root, mirroring derive_nucleus_user_root in
 * src/scripts/lib/lib.sh and the harness bridge extensions.
 */
export function nucleusUserRoot(
	platform: NodeJS.Platform = process.platform,
	env: NodeJS.ProcessEnv = process.env,
	home: () => string = homedir,
): string {
	if (platform === "darwin") {
		return join(home(), "Library", "Application Support", "nucleus");
	}
	if (platform === "win32") {
		const localAppData = env.LOCALAPPDATA;
		return localAppData ? join(localAppData, "nucleus") : join(home(), "AppData", "Local", "nucleus");
	}
	return join(home(), ".local", "share", "nucleus");
}

export function piQueuedCommandsDir(root: string): string {
	return join(root, "state", "harness-bridge", "commands", "pi");
}

/**
 * Read the newest queued harness-bridge prompt for pi without consuming it.
 * Returns the prompt text, or null when the queue is empty or unreadable.
 */
export function readQueuedPrompt(commandsDir: string): string | null {
	let names: string[];
	try {
		names = readdirSync(commandsDir).filter((name) => name.endsWith(".json"));
	} catch {
		return null;
	}

	let newest = "";
	for (const name of names) {
		if (name > newest) {
			newest = name;
		}
	}
	if (newest === "") {
		return null;
	}

	try {
		const queued = JSON.parse(readFileSync(join(commandsDir, newest), "utf8")) as { text?: unknown };
		if (typeof queued.text === "string") {
			const text = queued.text.trim();
			return text === "" ? null : text;
		}
		return null;
	} catch {
		return null;
	}
}

function isRecord(value: unknown): value is Record<string, unknown> {
	return typeof value === "object" && value !== null;
}

export function extractUserMessageText(content: unknown): string | null {
	if (typeof content === "string") {
		return content;
	}
	if (!Array.isArray(content)) {
		return null;
	}
	const parts: string[] = [];
	for (const item of content) {
		if (isRecord(item) && item.type === "text" && typeof item.text === "string") {
			parts.push(item.text);
		}
	}
	if (parts.length === 0) {
		return null;
	}
	return parts.join("\n");
}

/**
 * Find the last user-role message actually sent to the model in the branch.
 */
export function findLastSentUserPrompt(branch: readonly unknown[]): PromptChoice | null {
	for (let index = branch.length - 1; index >= 0; index -= 1) {
		const entry = branch[index];
		if (!isRecord(entry) || entry.type !== "message") {
			continue;
		}
		const message = entry.message;
		if (!isRecord(message) || message.role !== "user") {
			continue;
		}
		const text = extractUserMessageText(message.content);
		if (text === null) {
			continue;
		}
		return { source: "sent", text };
	}
	return null;
}

export function parsePromptSourceArg(args: string): PromptSource | "pick" | { error: string } {
	const trimmed = args.trim();
	if (trimmed === "") {
		return "sent";
	}
	const lower = trimmed.toLowerCase();
	if (lower === "sent" || lower === "queued" || lower === "pick") {
		return lower;
	}
	return { error: `Unknown prompt source "${trimmed}". Use sent, queued, or pick.` };
}

export function promptPreview(text: string, maxLength = 60): string {
	const oneLine = text.replace(/\s+/g, " ").trim();
	if (oneLine.length <= maxLength) {
		return oneLine;
	}
	return `${oneLine.slice(0, Math.max(0, maxLength - 1))}\u2026`;
}

function promptOptionLabel(choice: PromptChoice): string {
	const label = choice.source === "sent" ? "Sent" : "Queued";
	return `${label}: ${promptPreview(choice.text)}`;
}

export async function pickPromptChoice(
	sent: PromptChoice | null,
	queued: PromptChoice | null,
	ui: ExtensionCommandContext["ui"],
): Promise<PromptChoice | null | "cancelled"> {
	const choices: PromptChoice[] = [];
	if (sent) {
		choices.push(sent);
	}
	if (queued) {
		choices.push(queued);
	}
	if (choices.length === 0) {
		return null;
	}

	const options = choices.map(promptOptionLabel);
	const selected = await ui.select("Select prompt", options);
	if (selected === undefined) {
		return "cancelled";
	}
	const index = options.indexOf(selected);
	if (index < 0) {
		return "cancelled";
	}
	return choices[index] ?? "cancelled";
}

export async function resolvePromptChoice(
	mode: PromptSource | "pick",
	ctx: Pick<ExtensionCommandContext, "sessionManager" | "ui">,
	deps: PromptToolsDeps = {},
): Promise<PromptChoice | null | "cancelled"> {
	const env = deps.env ?? process.env;
	const root = nucleusUserRoot(deps.platform ?? process.platform, env, deps.homeDir ?? homedir);
	const queuedText = (deps.readQueuedPrompt ?? readQueuedPrompt)(piQueuedCommandsDir(root));
	const queued: PromptChoice | null = queuedText === null ? null : { source: "queued", text: queuedText };

	const branch = typeof ctx.sessionManager.getBranch === "function" ? ctx.sessionManager.getBranch() : [];
	const sent = findLastSentUserPrompt(branch as readonly unknown[]);

	if (mode === "sent") {
		return sent;
	}
	if (mode === "queued") {
		return queued;
	}
	return pickPromptChoice(sent, queued, ctx.ui);
}

export function defaultWriteToCommandStdin(command: string, args: readonly string[], text: string): Promise<boolean> {
	return new Promise((resolve) => {
		const child = spawn(command, [...args], { stdio: ["pipe", "ignore", "ignore"] });
		let settled = false;
		const finish = (ok: boolean): void => {
			if (settled) {
				return;
			}
			settled = true;
			resolve(ok);
		};
		child.on("error", () => finish(false));
		child.on("close", (code) => finish(code === 0));
		if (child.stdin) {
			child.stdin.on("error", () => finish(false));
			child.stdin.end(text);
		} else {
			finish(false);
		}
	});
}

export function clipboardCommands(platform: NodeJS.Platform): Array<{ command: string; args: string[] }> {
	if (platform === "darwin") {
		return [{ command: "pbcopy", args: [] }];
	}
	if (platform === "win32") {
		return [{ command: "clip", args: [] }];
	}
	return [
		{ command: "wl-copy", args: [] },
		{ command: "xclip", args: ["-selection", "clipboard"] },
		{ command: "xsel", args: ["--clipboard", "--input"] },
	];
}

export async function copyTextToClipboard(
	text: string,
	deps: PromptToolsDeps = {},
): Promise<boolean> {
	if (deps.copyToClipboard) {
		return deps.copyToClipboard(text);
	}
	const writer = deps.writeToCommandStdin ?? defaultWriteToCommandStdin;
	for (const candidate of clipboardCommands(deps.platform ?? process.platform)) {
		const ok = await writer(candidate.command, candidate.args, text);
		if (ok) {
			return true;
		}
	}
	return false;
}

function hasAnySentMessage(ctx: Pick<ExtensionCommandContext, "sessionManager">): boolean {
	const branch = typeof ctx.sessionManager.getBranch === "function" ? ctx.sessionManager.getBranch() : [];
	return findLastSentUserPrompt(branch as readonly unknown[]) !== null;
}

function unavailableSourceMessage(mode: PromptSource | "pick", command: "copy" | "repeat" | "continue", choice: PromptChoice | null): string | null {
	if (choice !== null) {
		return null;
	}
	if (mode === "queued") {
		return command === "copy" ? NOTHING_TO_COPY_QUEUED_MESSAGE : NOTHING_TO_REPEAT_QUEUED_MESSAGE;
	}
	return EMPTY_SESSION_MESSAGE;
}

async function showCopyFallback(ui: ExtensionCommandContext["ui"], text: string): Promise<void> {
	ui.notify(`Clipboard unavailable. Prompt:\n${text}`, "info");
}

export async function handleCopyUserPrompt(
	args: string,
	ctx: ExtensionCommandContext,
	deps: PromptToolsDeps = {},
): Promise<void> {
	const mode = parsePromptSourceArg(args);
	if (typeof mode === "object") {
		ctx.ui.notify(mode.error, "error");
		return;
	}

	const choice = await resolvePromptChoice(mode, ctx, deps);
	if (choice === "cancelled") {
		return;
	}
	const message = unavailableSourceMessage(mode, "copy", choice);
	if (message) {
		ctx.ui.notify(message, "info");
		return;
	}
	if (!choice) {
		ctx.ui.notify(EMPTY_SESSION_MESSAGE, "info");
		return;
	}

	const copied = await copyTextToClipboard(choice.text, deps);
	if (copied) {
		ctx.ui.notify(`Copied ${choice.source} prompt to clipboard.`, "info");
		return;
	}
	await showCopyFallback(ctx.ui, choice.text);
}

async function sendPromptAsNewTurn(
	text: string,
	ctx: ExtensionCommandContext,
	pi: Pick<ExtensionAPI, "sendUserMessage">,
): Promise<void> {
	if (ctx.isIdle()) {
		pi.sendUserMessage(text);
		return;
	}
	pi.sendUserMessage(text, { deliverAs: "followUp" });
}

export async function handleRepeatUserPrompt(
	args: string,
	ctx: ExtensionCommandContext,
	pi: Pick<ExtensionAPI, "sendUserMessage">,
	deps: PromptToolsDeps = {},
): Promise<void> {
	const mode = parsePromptSourceArg(args);
	if (typeof mode === "object") {
		ctx.ui.notify(mode.error, "error");
		return;
	}

	const choice = await resolvePromptChoice(mode, ctx, deps);
	if (choice === "cancelled") {
		return;
	}
	const message = unavailableSourceMessage(mode, "repeat", choice);
	if (message) {
		ctx.ui.notify(message, "info");
		return;
	}
	if (!choice) {
		ctx.ui.notify(EMPTY_SESSION_MESSAGE, "info");
		return;
	}

	if (!ctx.isIdle()) {
		const confirmed = await ctx.ui.confirm(
			"Repeat prompt?",
			"A turn is streaming. Resubmit this prompt as a new user turn?",
		);
		if (!confirmed) {
			return;
		}
	}

	await sendPromptAsNewTurn(choice.text, ctx, pi);
	if (!ctx.isIdle()) {
		ctx.ui.notify(`Queued ${choice.source} prompt as a follow-up turn.`, "info");
	}
}

export async function handleContinue(
	_ctxArgs: string,
	ctx: ExtensionCommandContext,
	pi: Pick<ExtensionAPI, "sendUserMessage">,
): Promise<void> {
	if (!hasAnySentMessage(ctx)) {
		ctx.ui.notify(NOTHING_TO_CONTINUE_MESSAGE, "info");
		return;
	}
	if (!ctx.isIdle()) {
		ctx.ui.notify("Agent is busy.", "warning");
		return;
	}
	pi.sendUserMessage(" ");
}

export function createPromptToolsExtension(
	deps: PromptToolsDeps = {},
): (pi: ExtensionAPI) => void {
	return function promptToolsExtension(pi: ExtensionAPI): void {
		pi.registerCommand("continue", {
			description: "Retry or continue the current turn",
			handler: async (args, ctx) => {
				await handleContinue(args, ctx as ExtensionCommandContext, pi);
			},
		});

		pi.registerCommand("copy-user-prompt", {
			description: "Copy a sent or queued prompt (default: sent)",
			handler: async (args, ctx) => {
				await handleCopyUserPrompt(args, ctx as ExtensionCommandContext, deps);
			},
		});

		pi.registerCommand("repeat-user-prompt", {
			description: "Resubmit a sent or queued prompt as a new user turn (default: sent)",
			handler: async (args, ctx) => {
				await handleRepeatUserPrompt(args, ctx as ExtensionCommandContext, pi, deps);
			},
		});
	};
}

export default createPromptToolsExtension();
