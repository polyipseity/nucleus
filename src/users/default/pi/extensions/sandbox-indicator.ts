/**
 * Sandbox state indicator for pi: reports whether the session is running inside
 * the nucleus srt sandbox via SANDBOX_RUNTIME, surfaces a status line, warns
 * once per process when unsandboxed, and exposes /sandbox-status for details.
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { statusText } from "./shared/status-style.ts";

export const STATUS_KEY = "sandbox";
export const SANDBOX_LABEL = "sandbox: srt";
export const UNSANDBOXED_LABEL = "sandbox: none";

export interface SandboxDetection {
	readonly sandboxed: boolean;
	readonly label: string;
	readonly evidence: string;
}

export interface SandboxStatusUi {
	readonly setStatus?: (key: string, value: string | undefined) => void;
	readonly notify?: (message: string, type?: string) => void;
}

export interface SandboxStatusContext {
	readonly hasUI?: boolean;
	readonly mode?: string;
	readonly ui?: SandboxStatusUi;
}

export interface SandboxDependencies {
	readonly env?: NodeJS.ProcessEnv;
	readonly cwd?: string;
	readonly commandPath?: (command: string) => string;
	readonly commandExists?: (command: string) => boolean;
	readonly readRegistryUnproven?: (env: NodeJS.ProcessEnv, cwd: string) => string;
}

let warnedUnsandboxed = false;

export function resetSandboxWarningForTests(): void {
	warnedUnsandboxed = false;
}

function isFalseLike(value: string): boolean {
	const normalized = value.toLowerCase();
	return normalized === "0" || normalized === "false";
}

export function detectSandbox(env: NodeJS.ProcessEnv = process.env): SandboxDetection {
	const raw = env.SANDBOX_RUNTIME;
	if (raw === undefined) {
		return { sandboxed: false, label: UNSANDBOXED_LABEL, evidence: "SANDBOX_RUNTIME unset" };
	}
	if (raw === "") {
		return { sandboxed: false, label: UNSANDBOXED_LABEL, evidence: "SANDBOX_RUNTIME empty string" };
	}
	if (isFalseLike(raw)) {
		return { sandboxed: false, label: UNSANDBOXED_LABEL, evidence: `SANDBOX_RUNTIME=${raw} (false-like)` };
	}
	return { sandboxed: true, label: SANDBOX_LABEL, evidence: `SANDBOX_RUNTIME=${raw}` };
}

function defaultCommandPath(command: string): string {
	try {
		const result = execFileSync("/bin/sh", ["-c", 'command -v -- "$1"', "sh", command], {
			encoding: "utf8",
		});
		const line = result.trim().split("\n")[0];
		return line.length > 0 ? line : "not found";
	} catch {
		return "not found";
	}
}

function defaultCommandExists(command: string): boolean {
	return defaultCommandPath(command) !== "not found";
}

export function readSafeDeleteUnproven(env: NodeJS.ProcessEnv = process.env, cwd: string = process.cwd()): string {
	const candidates: string[] = [];
	const repoRoot = env.NUCLEUS_REPO_ROOT;
	if (typeof repoRoot === "string" && repoRoot.length > 0) {
		candidates.push(join(repoRoot, "src/modules/configs/harness-filters.json"));
	}
	candidates.push(join(cwd, "src/modules/configs/harness-filters.json"));

	for (const candidate of candidates) {
		try {
			const raw = readFileSync(candidate, "utf8");
			const parsed = JSON.parse(raw) as unknown;
			if (typeof parsed !== "object" || parsed === null) {
				continue;
			}
			const filters = (parsed as { filters?: unknown }).filters;
			if (!Array.isArray(filters)) {
				continue;
			}
			for (const entry of filters) {
				if (typeof entry !== "object" || entry === null) {
					continue;
				}
				if ((entry as { id?: unknown }).id === "safe-delete") {
					const settings = (entry as { settings?: unknown }).settings;
					if (typeof settings === "object" && settings !== null) {
						const unproven = (settings as { unproven?: unknown }).unproven;
						if (typeof unproven === "string") {
							return unproven;
						}
					}
					return "unavailable";
				}
			}
			return "unavailable";
		} catch {
			continue;
		}
	}
	return "unavailable";
}

function getContext(value: unknown): SandboxStatusContext {
	if (typeof value === "object" && value !== null) {
		return value as SandboxStatusContext;
	}
	return {};
}

function applySandboxState(ctx: SandboxStatusContext, env: NodeJS.ProcessEnv): void {
	const detection = detectSandbox(env);
	if (ctx.ui && typeof ctx.ui.setStatus === "function") {
		const status = detection.sandboxed
			? detection.label
			: statusText(detection.label, "warning", env);
		ctx.ui.setStatus(STATUS_KEY, status);
	}
	if (!detection.sandboxed && ctx.hasUI === true && !warnedUnsandboxed) {
		warnedUnsandboxed = true;
		if (ctx.ui && typeof ctx.ui.notify === "function") {
			ctx.ui.notify("Running unsandboxed (SANDBOX_RUNTIME not set).", "warning");
		}
	}
}

export function buildSandboxStatusReport(
	ctx: SandboxStatusContext,
	deps: SandboxDependencies = {},
): string {
	const env = deps.env ?? process.env;
	const cwd = deps.cwd ?? process.cwd();
	const detection = detectSandbox(env);
	const commandPath = deps.commandPath ?? defaultCommandPath;
	const commandExists = deps.commandExists ?? defaultCommandExists;
	const readUnproven = deps.readRegistryUnproven ?? readSafeDeleteUnproven;

	const state = detection.sandboxed ? "sandboxed" : "unsandboxed";
	const mode = typeof ctx.mode === "string" ? ctx.mode : "unknown";
	const rmPath = commandPath("rm");
	const filterPath = commandPath("harness-filter");
	const filterDisplay = filterPath === "not found" ? "missing" : filterPath;
	const safeRmPresent = commandExists("shell-safe-rm");
	const ripPresent = commandExists("rip");
	const unproven = readUnproven(env, cwd);

	return [
		`state: ${state}`,
		`evidence: ${detection.evidence}`,
		`ctx.mode: ${mode}`,
		`rm: ${rmPath}`,
		`shell-safe-rm present: ${safeRmPresent}`,
		`rip present: ${ripPresent}`,
		`harness-filter: ${filterDisplay}`,
		`safe-delete.settings.unproven: ${unproven}`,
	].join("\n");
}

export function createSandboxIndicatorExtension(
	deps: SandboxDependencies = {},
): (pi: ExtensionAPI) => void {
	const env = deps.env ?? process.env;
	return function (pi: ExtensionAPI): void {
		pi.on("session_start", (_event: unknown, ctx: unknown) => {
			applySandboxState(getContext(ctx), env);
		});

		pi.on("session_compact", (_event: unknown, ctx: unknown) => {
			applySandboxState(getContext(ctx), env);
		});

		pi.on("session_shutdown", (_event: unknown, ctx: unknown) => {
			const context = getContext(ctx);
			if (context.ui && typeof context.ui.setStatus === "function") {
				context.ui.setStatus(STATUS_KEY, undefined);
			}
		});

		pi.registerCommand("sandbox-status", {
			description: "Show sandbox state and deletion-safety tooling status",
			handler: async (_args: string, ctx: unknown) => {
				const context = getContext(ctx);
				const report = buildSandboxStatusReport(context, deps);
				if (context.ui && typeof context.ui.notify === "function") {
					context.ui.notify(report, "info");
				}
			},
		});
	};
}

export default createSandboxIndicatorExtension();
