/**
 * Pi prompt tools: /continue, /copy-user-prompt, /repeat-user-prompt.
 *
 * Semantics are shared: `sent`/`queued` shortcuts return the newest prompt of
 * that kind, and `pick` lists every retained sent and queued prompt in reverse
 * chronological order behind a text filter. Queued prompts are read without
 * consumption. Copy prefers the shared harness-clipboard command with a
 * selectable-text fallback, repeat resubmits as a new user turn and confirms
 * while streaming, and continue retries or continues the turn.
 */

import type { ExtensionAPI, ExtensionCommandContext } from "@earendil-works/pi-coding-agent";
type SelectItem = { value: string; label: string; description?: string };
type SelectListTheme = {
	selectedPrefix: (text: string) => string;
	selectedText: (text: string) => string;
	description: (text: string) => string;
	scrollInfo: (text: string) => string;
	noMatch: (text: string) => string;
};

interface PiTuiModule {
	fuzzyFilter: <T>(items: T[], query: string, getText: (item: T) => string) => T[];
	Input: new () => {
		getValue(): string;
		setValue(value: string): void;
		handleInput(data: string): void;
		render(width: number): string[];
		invalidate?(): void;
		focused?: boolean;
	};
	SelectList: new (items: SelectItem[], maxVisible: number, theme: SelectListTheme) => {
		setSelectedIndex(index: number): void;
		getSelectedItem(): SelectItem | null;
		getSelectedIndex?(): number;
		render(width: number): string[];
		handleInput(data: string): void;
		invalidate?(): void;
		onSelect?: (item: SelectItem) => void;
		onCancel?: () => void;
	};
	truncateToWidth: (text: string, width: number, ellipsis?: string) => string;
}

let piTui: PiTuiModule | undefined;
async function loadPiTui(): Promise<PiTuiModule> {
	if (!piTui) {
		piTui = (await import("@earendil-works/pi-tui")) as unknown as PiTuiModule;
	}
	return piTui;
}
function requirePiTui(): PiTuiModule {
	if (!piTui) {
		throw new Error("pi-tui is not loaded");
	}
	return piTui;
}
// preload for sync rendering in interactive TUI
void loadPiTui().catch(() => {});
import { spawn } from "node:child_process";
import { readdirSync, readFileSync, statSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

export const EMPTY_SESSION_MESSAGE = "Nothing to repeat yet \u2014 this session has no user message.";
export const NOTHING_TO_COPY_QUEUED_MESSAGE = "Nothing to copy yet \u2014 no queued prompt.";
export const NOTHING_TO_REPEAT_QUEUED_MESSAGE = "Nothing to repeat yet \u2014 no queued prompt.";
export const NOTHING_TO_CONTINUE_MESSAGE = EMPTY_SESSION_MESSAGE;

export type PromptSource = "sent" | "queued";

export interface SentPrompt {
	readonly text: string;
	readonly timestamp?: string;
}

export interface QueuedPrompt {
	readonly text: string;
	readonly mtimeMs: number;
}

export interface PromptChoice {
	readonly source: PromptSource;
	readonly text: string;
	readonly timestamp?: string;
	readonly mtimeMs?: number;
}

export interface PromptToolsDeps {
	readonly env?: NodeJS.ProcessEnv;
	readonly platform?: NodeJS.Platform;
	readonly homeDir?: () => string;
	readonly now?: () => number;
	readonly readQueuedPrompt?: (commandsDir: string) => string | null;
	readonly readQueuedPromptList?: (commandsDir: string) => readonly QueuedPrompt[];
	readonly copyToClipboard?: (text: string) => Promise<boolean>;
	readonly writeToCommandStdin?: (command: string, args: readonly string[], text: string) => Promise<boolean>;
	readonly isCompacting?: () => boolean;
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

function queuedPromptText(value: unknown): string | null {
	if (!isRecord(value) || typeof value.text !== "string") {
		return null;
	}
	const text = value.text.trim();
	return text === "" ? null : text;
}

/**
 * Read all queued harness-bridge prompts for pi without consuming them.
 * Returns prompts with non-empty text only.
 */
export function readQueuedPromptList(commandsDir: string): readonly QueuedPrompt[] {
	let names: string[];
	try {
		names = readdirSync(commandsDir).filter((name) => name.endsWith(".json"));
	} catch {
		return [];
	}

	const prompts: QueuedPrompt[] = [];
	for (const name of names) {
		const path = join(commandsDir, name);
		try {
			const text = queuedPromptText(JSON.parse(readFileSync(path, "utf8")));
			if (text === null) {
				continue;
			}
			const mtimeMs = statSync(path).mtimeMs;
			prompts.push({ text, mtimeMs });
		} catch {
			// unreadable/invalid queued entries are ignored
		}
	}
	return prompts;
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
		return queuedPromptText(JSON.parse(readFileSync(join(commandsDir, newest), "utf8")));
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

function sentPromptTimestamp(message: Record<string, unknown>, entry: Record<string, unknown>): string | undefined {
	const candidates = [message.timestamp, entry.timestamp];
	for (const value of candidates) {
		if (typeof value === "string" && value.trim() !== "") {
			return value;
		}
	}
	return undefined;
}

/**
 * Find all user-role messages actually sent to the model in branch order
 * (oldest first, newest last).
 */
export function findSentUserPrompts(branch: readonly unknown[]): readonly SentPrompt[] {
	const prompts: SentPrompt[] = [];
	for (const entry of branch) {
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
		const timestamp = sentPromptTimestamp(message, entry);
		prompts.push(timestamp === undefined ? { text } : { text, timestamp });
	}
	return prompts;
}

/**
 * Find the last user-role message actually sent to the model in the branch.
 */
export function findLastSentUserPrompt(branch: readonly unknown[]): PromptChoice | null {
	const prompts = findSentUserPrompts(branch);
	const last = prompts[prompts.length - 1];
	return last ? { source: "sent", text: last.text, timestamp: last.timestamp } : null;
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

function formatRelativeAge(ms: number): string {
	const seconds = Math.max(0, Math.floor(ms / 1000));
	if (seconds < 60) {
		return `${seconds}s`;
	}
	const minutes = Math.floor(seconds / 60);
	if (minutes < 60) {
		return `${minutes}m`;
	}
	const hours = Math.floor(minutes / 60);
	if (hours < 24) {
		return `${hours}h`;
	}
	return `${Math.floor(hours / 24)}d`;
}

function pickLabel(choice: PromptChoice, nowMs: number): string {
	const kind = choice.source === "sent" ? "sent" : "queued";
	let when = "now";
	if (choice.source === "queued" && typeof choice.mtimeMs === "number") {
		when = formatRelativeAge(nowMs - choice.mtimeMs);
	} else if (choice.source === "sent" && typeof choice.timestamp === "string") {
		const ts = Date.parse(choice.timestamp);
		if (!Number.isNaN(ts)) {
			when = formatRelativeAge(nowMs - ts);
		}
	}
	return `${kind} · ${when} · ${promptPreview(choice.text)}`;
}

function parseSentTimestamp(timestamp?: string): number | null {
	if (typeof timestamp !== "string") {
		return null;
	}
	const ms = Date.parse(timestamp);
	return Number.isNaN(ms) ? null : ms;
}

export function buildPromptChoices(sent: readonly SentPrompt[], queued: readonly QueuedPrompt[]): readonly PromptChoice[] {
	const sentChoices = sent.map(
		(prompt, index): PromptChoice & { readonly index: number; readonly ts: number | null } => ({
			source: "sent",
			text: prompt.text,
			timestamp: prompt.timestamp,
			index,
			ts: parseSentTimestamp(prompt.timestamp),
		}),
	);
	const queuedChoices = [...queued]
		.sort((a, b) => b.mtimeMs - a.mtimeMs)
		.map(
			(prompt): PromptChoice & { readonly ts: number } => ({
				source: "queued",
				text: prompt.text,
				mtimeMs: prompt.mtimeMs,
				ts: prompt.mtimeMs,
			}),
		);

	const anySentTimestamp = sentChoices.some((choice) => choice.ts !== null);
	if (!anySentTimestamp) {
		// Preserve legacy sent-first highlight for the simple 1 sent + 1 queued case.
		if (sentChoices.length === 1 && queuedChoices.length === 1) {
			return [sentChoices[0], queuedChoices[0]].map(({ source, text, timestamp, mtimeMs }) => ({
				source,
				text,
				timestamp,
				mtimeMs,
			}));
		}
		const sentNewestFirst = [...sentChoices].sort((a, b) => b.index - a.index);
		return [...queuedChoices, ...sentNewestFirst].map(({ source, text, timestamp, mtimeMs }) => ({
			source,
			text,
			timestamp,
			mtimeMs,
		}));
	}

	const mixed = [
		...queuedChoices.map((choice) => ({ ...choice, sentIndex: -1 })),
		...sentChoices
			.filter((choice) => choice.ts !== null)
			.map((choice) => ({ ...choice, sentIndex: choice.index })),
	];
	mixed.sort((a, b) => {
		if (b.ts !== a.ts) {
			return b.ts - a.ts;
		}
		if (a.source !== b.source) {
			return a.source === "queued" ? -1 : 1;
		}
		return b.sentIndex - a.sentIndex;
	});
	const untimedSent = sentChoices.filter((choice) => choice.ts === null).sort((a, b) => b.index - a.index);
	return [...mixed, ...untimedSent].map(({ source, text, timestamp, mtimeMs }) => ({
		source,
		text,
		timestamp,
		mtimeMs,
	}));
}

export function filterPromptChoices(
	choices: readonly PromptChoice[],
	filter: string,
): readonly PromptChoice[] {
	if (filter === "") {
		return choices;
	}
	const needle = filter.toLowerCase();
	return choices.filter((choice) => choice.text.toLowerCase().includes(needle));
}

function isPickerUi(value: unknown): value is ExtensionCommandContext["ui"] {
	return isRecord(value) && typeof value.select === "function";
}

function isCustomPickerUi(
	value: unknown,
): value is ExtensionCommandContext["ui"] & { custom: NonNullable<ExtensionCommandContext["ui"]["custom"]> } {
	return isRecord(value) && typeof value.custom === "function";
}

export interface PromptPickerComponent {
	render(width: number): string[];
	handleInput?(data: string): void;
	invalidate?(): void;
}

interface PickerUiDeps {
	readonly tui?: { requestRender?: () => void };
	readonly theme?: {
		fg?: (color: string, text: string) => string;
		bold?: (text: string) => string;
	};
	readonly keybindings?: { matches?: (data: string, binding: string) => boolean };
	readonly piTuiModule?: PiTuiModule;
}

const PICKER_VISIBLE_ROWS = 10;

function promptPickerTheme(theme?: PickerUiDeps["theme"]): SelectListTheme {
	const fg = theme?.fg ?? ((_color: string, text: string) => text);
	return {
		selectedPrefix: (text) => fg("accent", text),
		selectedText: (text) => fg("accent", text),
		description: (text) => fg("muted", text),
		scrollInfo: (text) => fg("dim", text),
		noMatch: (text) => fg("warning", text),
	};
}

export function createPromptPickerComponent(
	choices: readonly PromptChoice[],
	done: (value: PromptChoice | undefined) => void,
	initialQuery = "",
	deps: PickerUiDeps = {},
): PromptPickerComponent {
	const tui = deps.piTuiModule ?? piTui;
	if (!tui) {
		throw new Error("pi-tui is not loaded");
	}
	const input = new tui.Input();
	if (initialQuery !== "") {
		input.setValue(initialQuery);
	}

	let filteredChoices: PromptChoice[] = [];
	let currentItems: Array<SelectItem & { choice: PromptChoice }> = [];
	let selectedIndex = 0;
	let list = new tui.SelectList([], PICKER_VISIBLE_ROWS, promptPickerTheme(deps.theme));

	const syncSelectedIndex = (): void => {
		const selected = list.getSelectedItem();
		if (!selected) {
			selectedIndex = filteredChoices.length === 0 ? 0 : Math.min(selectedIndex, filteredChoices.length - 1);
			return;
		}
		const index = currentItems.findIndex((item) => item.value === selected.value && item.label === selected.label);
		selectedIndex = index >= 0 ? index : 0;
	};

	const renderQuery = (): void => {
		const query = input.getValue();
		currentItems = tui
			.fuzzyFilter([...choices], query, (choice) => `${promptOptionLabel(choice)} ${choice.text}`)
			.map((choice) => ({
				value: `${choice.source}\u0000${choice.text}`,
				label: promptOptionLabel(choice),
				description: "",
				choice,
			}));
		const previousValue = list.getSelectedItem()?.value;
		filteredChoices = currentItems.map((item) => item.choice);
		list = new tui.SelectList(
			currentItems.map(({ value, label, description }) => ({ value, label, description }) satisfies SelectItem),
			PICKER_VISIBLE_ROWS,
			promptPickerTheme(deps.theme),
		);
		selectedIndex = 0;
		if (previousValue) {
			const index = currentItems.findIndex((item) => item.value === previousValue);
			if (index >= 0) {
				selectedIndex = index;
				list.setSelectedIndex(index);
			}
		}
		list.onSelect = (item) => {
			const index = currentItems.findIndex((candidate) => candidate.value === item.value && candidate.label === item.label);
			done(index >= 0 ? currentItems[index].choice : undefined);
		};
		list.onCancel = () => {
			done(undefined);
		};
		list.onSelectionChange = () => {
			syncSelectedIndex();
		};
	};

	renderQuery();

	const requestRender = (): void => {
		deps.tui?.requestRender?.();
	};

	const isCancel = (data: string): boolean =>
		deps.keybindings?.matches?.(data, "tui.select.cancel") === true || data === "\x1b" || data === "\x1b\x1b";

	const isPrintable = (data: string): boolean => data.length === 1 && data >= " " && data !== "\x7f";

	return {
		render(width: number): string[] {
			const queryLine = tui.truncateToWidth(`Filter: ${input.getValue()}`, width, "");
			const listLines = list.render(width).map((line) => tui.truncateToWidth(line, width, ""));
			return [queryLine, "", ...listLines];
		},
		handleInput(data: string): void {
			if (isCancel(data)) {
				done(undefined);
				requestRender();
				return;
			}
			if (data === "\r" || data === "\n") {
				syncSelectedIndex();
				const choice = filteredChoices[selectedIndex];
				if (choice) {
					done(choice);
				}
				requestRender();
				return;
			}

			const beforeQuery = input.getValue();
			const beforeIndex = selectedIndex;
			if (
				data === "\x1b[A" ||
				data === "\x1bOA" ||
				data === "\x1b[B" ||
				data === "\x1bOB" ||
				data === "\x1b[5~" ||
				data === "\x1b[6~"
			) {
				list.handleInput(data);
				syncSelectedIndex();
			} else {
				input.handleInput(data);
			}

			if (input.getValue() !== beforeQuery) {
				renderQuery();
			}
			if (input.getValue() !== beforeQuery || selectedIndex !== beforeIndex || isPrintable(data) || data === "\x7f" || data === "\b" || data === "\x1b[3~") {
				requestRender();
			}
		},
		invalidate(): void {
			input.invalidate?.();
			list.invalidate?.();
		},
	};
}

async function pickPromptWithCustom(
	choices: readonly PromptChoice[],
	ui: ExtensionCommandContext["ui"] & { custom: NonNullable<ExtensionCommandContext["ui"]["custom"]> },
	initialQuery = "",
): Promise<PromptChoice | null | "cancelled"> {
	if (choices.length === 0) {
		return null;
	}
	await loadPiTui();
	const selected = await ui.custom<PromptChoice | undefined>((tui, theme, keybindings, done) =>
		createPromptPickerComponent(choices, done, initialQuery, { tui, theme, keybindings }),
	);
	return selected === undefined ? "cancelled" : selected;
}

export async function pickPromptChoice(
	first: PromptChoice | readonly PromptChoice[] | null,
	second: PromptChoice | string | ExtensionCommandContext["ui"] | null,
	third?: ExtensionCommandContext["ui"],
): Promise<PromptChoice | null | "cancelled"> {
	// New signature: (choices, filter, ui)
	if (third && isPickerUi(third) && typeof second === "string") {
		const choices = (first ?? []) as readonly PromptChoice[];
		const filter = second;
		const ui = third;
		if (isCustomPickerUi(ui)) {
			return pickPromptWithCustom(choices, ui, filter);
		}
		const filtered = filterPromptChoices(choices, filter);
		if (filtered.length === 0) {
			return null;
		}
		const options = filtered.map(promptOptionLabel);
		const selected = await ui.select("Select prompt", options);
		if (selected === undefined) {
			return "cancelled";
		}
		let index = options.indexOf(selected);
		if (index < 0) {
			if (selected.startsWith("Sent:")) {
				index = filtered.findIndex((choice) => choice.source === "sent");
			} else if (selected.startsWith("Queued:")) {
				index = filtered.findIndex((choice) => choice.source === "queued");
			}
		}
		return index < 0 ? "cancelled" : filtered[index] ?? "cancelled";
	}

	// Legacy signature: (sent, queued, ui) — preserves existing labels/behavior.
	if (third || isPickerUi(second)) {
		const sent = first as PromptChoice | null;
		const queued = isPickerUi(second) ? null : (second as PromptChoice | null);
		const ui = (isPickerUi(second) ? second : third) as ExtensionCommandContext["ui"];
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
		if (isCustomPickerUi(ui)) {
			return pickPromptWithCustom(choices, ui);
		}
		const options = choices.map(promptOptionLabel);
		const selected = await ui.select("Select prompt", options);
		if (selected === undefined) {
			return "cancelled";
		}
		let index = options.indexOf(selected);
		if (index < 0) {
			if (selected.startsWith("Sent:")) {
				index = choices.findIndex((choice) => choice.source === "sent");
			} else if (selected.startsWith("Queued:")) {
				index = choices.findIndex((choice) => choice.source === "queued");
			}
		}
		return index < 0 ? "cancelled" : choices[index] ?? "cancelled";
	}

	// Back-compat: treat missing ui/filter as no choices when called oddly.
	const choices = (first ?? []) as readonly PromptChoice[];
	const filter = typeof second === "string" ? second : "";
	const ui = third as ExtensionCommandContext["ui"] | undefined;
	if (!ui || !isPickerUi(ui)) {
		return null;
	}
	const filtered = filterPromptChoices(choices, filter);
	if (filtered.length === 0) {
		return null;
	}
	const options = filtered.map(promptOptionLabel);
	const selected = await ui.select("Select prompt", options);
	if (selected === undefined) {
		return "cancelled";
	}
	let index = options.indexOf(selected);
	if (index < 0) {
		if (selected.startsWith("Sent:")) {
			index = filtered.findIndex((choice) => choice.source === "sent");
		} else if (selected.startsWith("Queued:")) {
			index = filtered.findIndex((choice) => choice.source === "queued");
		}
	}
	return index < 0 ? "cancelled" : filtered[index] ?? "cancelled";
}

function resolveQueuedPrompts(commandsDir: string, deps: PromptToolsDeps): readonly QueuedPrompt[] {
	if (deps.readQueuedPromptList) {
		return deps.readQueuedPromptList(commandsDir);
	}
	if (deps.readQueuedPrompt) {
		const text = deps.readQueuedPrompt(commandsDir);
		return text === null ? [] : [{ text, mtimeMs: Date.now() }];
	}
	return readQueuedPromptList(commandsDir);
}

function newestQueuedChoice(queued: readonly QueuedPrompt[]): PromptChoice | null {
	if (queued.length === 0) {
		return null;
	}
	const newest = [...queued].sort((a, b) => b.mtimeMs - a.mtimeMs)[0];
	return newest ? { source: "queued", text: newest.text } : null;
}

async function promptForFilter(ui: ExtensionCommandContext["ui"]): Promise<string | "cancelled"> {
	const uiWithInput = ui as ExtensionCommandContext["ui"] & {
		input?: (title: string, placeholder?: string) => Promise<string | undefined>;
	};
	if (typeof uiWithInput.input === "function") {
		const value = await uiWithInput.input("Filter prompts", "text filter (empty for all)");
		if (value === undefined) {
			return "cancelled";
		}
		return value;
	}
	return "";
}

export async function resolvePromptChoice(
	mode: PromptSource | "pick",
	ctx: Pick<ExtensionCommandContext, "sessionManager" | "ui">,
	deps: PromptToolsDeps = {},
): Promise<PromptChoice | null | "cancelled"> {
	const env = deps.env ?? process.env;
	const root = nucleusUserRoot(deps.platform ?? process.platform, env, deps.homeDir ?? homedir);
	const commandsDir = piQueuedCommandsDir(root);
	const branch = typeof ctx.sessionManager.getBranch === "function" ? ctx.sessionManager.getBranch() : [];
	const sentPrompts = findSentUserPrompts(branch as readonly unknown[]);
	const queuedPrompts = resolveQueuedPrompts(commandsDir, deps);

	if (mode === "sent") {
		const last = sentPrompts[sentPrompts.length - 1];
		return last ? { source: "sent", text: last.text, timestamp: last.timestamp } : null;
	}
	if (mode === "queued") {
		return newestQueuedChoice(queuedPrompts);
	}

	const choices = buildPromptChoices(sentPrompts, queuedPrompts);
	if (choices.length === 0) {
		return null;
	}
	const sent = sentPrompts[sentPrompts.length - 1]
		? { source: "sent" as const, text: sentPrompts[sentPrompts.length - 1].text, timestamp: sentPrompts[sentPrompts.length - 1].timestamp }
		: null;
	const queued = newestQueuedChoice(queuedPrompts);
	const legacyTwo =
		sentPrompts.length <= 1 &&
		queuedPrompts.length <= 1 &&
		!sentPrompts.some((prompt) => typeof prompt.timestamp === "string" && prompt.timestamp.trim() !== "");
	if (legacyTwo) {
		return pickPromptChoice(sent, queued, ctx.ui);
	}

	if (isCustomPickerUi(ctx.ui)) {
		return pickPromptWithCustom(choices, ctx.ui, "");
	}

	const filter = await promptForFilter(ctx.ui);
	if (filter === "cancelled") {
		return "cancelled";
	}
	const filtered = filterPromptChoices(choices, filter);
	if (filtered.length === 0) {
		return null;
	}
	const nowMs = (deps.now ?? Date.now)();
	const options = filtered.map((choice) => pickLabel(choice, nowMs));
	const selected = await ctx.ui.select("Select prompt", options);
	if (selected === undefined) {
		return "cancelled";
	}
	let index = options.indexOf(selected);
	if (index < 0) {
		index = filtered.findIndex((choice) => promptOptionLabel(choice) === selected);
	}
	if (index < 0) {
		if (selected.startsWith("Sent:")) {
			index = filtered.findIndex((choice) => choice.source === "sent");
		} else if (selected.startsWith("Queued:")) {
			index = filtered.findIndex((choice) => choice.source === "queued");
		}
	}
	if (index < 0) {
		return "cancelled";
	}
	return filtered[index] ?? "cancelled";
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

function harnessClipboardCommands(): Array<{ command: string; args: string[] }> {
	const here = dirname(fileURLToPath(import.meta.url));
	const scriptDir = join(here, "..", "..", "..", "..", "..", "src", "scripts", "notify");
	return [
		{ command: "harness-clipboard", args: [] },
		{ command: "bash", args: [join(scriptDir, "harness-clipboard.sh")] },
		{ command: "pwsh", args: ["-NoProfile", "-File", join(scriptDir, "harness-clipboard.ps1")] },
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
	if (!deps.writeToCommandStdin) {
		for (const candidate of harnessClipboardCommands()) {
			const ok = await writer(candidate.command, candidate.args, text);
			if (ok) {
				return true;
			}
		}
	}
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

type PromptSendMode = "immediate" | "followUp" | "waited";

function isCompactingState(isCompacting?: () => boolean): boolean {
	return typeof isCompacting === "function" && isCompacting();
}

async function waitForContextIdle(ctx: ExtensionCommandContext): Promise<void> {
	const waitForIdle = (ctx as ExtensionCommandContext & { waitForIdle?: () => Promise<void> }).waitForIdle;
	if (typeof waitForIdle === "function") {
		await waitForIdle.call(ctx);
	}
}

async function sendPromptText(
	text: string,
	ctx: ExtensionCommandContext,
	pi: Pick<ExtensionAPI, "sendUserMessage">,
	isCompacting?: () => boolean,
): Promise<PromptSendMode> {
	if (isCompactingState(isCompacting)) {
		await waitForContextIdle(ctx);
		pi.sendUserMessage(text);
		return "waited";
	}
	if (ctx.isIdle()) {
		pi.sendUserMessage(text);
		return "immediate";
	}
	pi.sendUserMessage(text, { deliverAs: "followUp" });
	return "followUp";
}

async function sendPromptAsNewTurn(
	text: string,
	ctx: ExtensionCommandContext,
	pi: Pick<ExtensionAPI, "sendUserMessage">,
	isCompacting?: () => boolean,
): Promise<void> {
	await sendPromptText(text, ctx, pi, isCompacting);
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

	const sendMode = await sendPromptText(choice.text, ctx, pi, deps.isCompacting);
	if (sendMode === "followUp") {
		ctx.ui.notify(`Queued ${choice.source} prompt as a follow-up turn.`, "info");
	} else if (sendMode === "waited") {
		ctx.ui.notify(`Queued ${choice.source} prompt.`, "info");
	}
}

export async function handleContinue(
	_ctxArgs: string,
	ctx: ExtensionCommandContext,
	pi: Pick<ExtensionAPI, "sendUserMessage">,
	options: { readonly isCompacting?: () => boolean } = {},
): Promise<void> {
	if (!hasAnySentMessage(ctx)) {
		ctx.ui.notify(NOTHING_TO_CONTINUE_MESSAGE, "info");
		return;
	}
	const mode = await sendPromptText(" ", ctx, pi, options.isCompacting);
	if (mode !== "immediate") {
		ctx.ui.notify("Queued /continue.", "info");
	}
}

export function createPromptToolsExtension(
	deps: PromptToolsDeps = {},
): (pi: ExtensionAPI) => void {
	return function promptToolsExtension(pi: ExtensionAPI): void {
		let compacting = false;
		const runtime = { isCompacting: () => compacting };

		pi.on("session_before_compact", async () => {
			compacting = true;
		});
		pi.on("session_compact", async () => {
			compacting = false;
		});
		pi.on("session_compact_failed", async () => {
			compacting = false;
		});

		pi.registerCommand("continue", {
			description: "Retry or continue the current turn",
			handler: async (args, ctx) => {
				await handleContinue(args, ctx as ExtensionCommandContext, pi, runtime);
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
				await handleRepeatUserPrompt(args, ctx as ExtensionCommandContext, pi, { ...deps, ...runtime });
			},
		});
	};
}

export default createPromptToolsExtension();
