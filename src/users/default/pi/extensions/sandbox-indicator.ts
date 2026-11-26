/**
 * Sandbox state indicator for pi: reports whether the session is running inside
 * the nucleus srt sandbox via SANDBOX_RUNTIME, surfaces a status line, warns
 * once per process when unsandboxed, and exposes /sandbox-status for details.
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { execFileSync, spawnSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { homedir } from "node:os";
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

export interface RedirectVerdict {
	readonly kind: "verdict";
	readonly decision: string;
	readonly rule: string;
	readonly reason: string;
}

export interface RedirectUnavailable {
	readonly kind: "unavailable";
	readonly reason: string;
}

export type RedirectProbeResult = RedirectVerdict | RedirectUnavailable;

export interface SandboxDependencies {
	readonly env?: NodeJS.ProcessEnv;
	readonly cwd?: string;
	readonly commandPath?: (command: string) => string;
	readonly readRegistryUnproven?: (env: NodeJS.ProcessEnv, cwd: string) => string;
	readonly readInjectOnChange?: (env: NodeJS.ProcessEnv, cwd: string) => boolean;
	readonly probeRedirect?: (
		env: NodeJS.ProcessEnv,
		cwd: string,
	) => Promise<RedirectProbeResult> | RedirectProbeResult;
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

function presentPath(path: string): string {
	return path === "not found" ? "absent" : path;
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

export function readSandboxContextInjectOnChange(
	env: NodeJS.ProcessEnv = process.env,
	_cwd: string = process.cwd(),
): boolean {
	const home = env.HOME ?? homedir();
	const configPath = join(home, ".local", "state", "nucleus", "config.json");
	try {
		const raw = readFileSync(configPath, "utf8");
		const parsed = JSON.parse(raw) as unknown;
		if (typeof parsed !== "object" || parsed === null) {
			return true;
		}
		const section = (parsed as Record<string, unknown>)["sandbox-context"];
		if (typeof section !== "object" || section === null) {
			return true;
		}
		const value = (section as Record<string, unknown>)["inject-on-change"];
		return typeof value === "boolean" ? value : true;
	} catch {
		return true;
	}
}

function parseRedirectVerdictLine(line: string): RedirectProbeResult | null {
	const trimmed = line.trim();
	if (trimmed.length === 0) {
		return null;
	}
	const parts = trimmed.split("\t");
	if (parts.length < 3) {
		return null;
	}
	const [decision, rule, ...reasonParts] = parts;
	if (!decision || !rule) {
		return null;
	}
	return { kind: "verdict", decision, rule, reason: reasonParts.join("\t") };
}

export function defaultProbeRedirect(
	env: NodeJS.ProcessEnv = process.env,
	_cwd: string = process.cwd(),
): RedirectProbeResult {
	const result = spawnSync(
		"nucleus-utils",
		["harness", "check-deletion", "--command", "rm -rf __nucleus_status_probe__"],
		{ encoding: "utf8", env, timeout: 10_000 },
	);

	if (result.error) {
		const err = result.error as NodeJS.ErrnoException;
		if (err.code === "ENOENT") {
			return { kind: "unavailable", reason: "nucleus-utils not on PATH" };
		}
		return { kind: "unavailable", reason: `harness check-deletion error: ${err.message}` };
	}

	if (result.status !== 0 || result.signal !== null) {
		const detail = [result.stderr?.trim(), result.status !== null ? `exit ${String(result.status)}` : null, result.signal]
			.filter((part): part is string => typeof part === "string" && part.length > 0)
			.join(", ");
		return { kind: "unavailable", reason: `harness check-deletion error: ${detail || "unknown error"}` };
	}

	const stdout = result.stdout ?? "";
	const lines = stdout
		.split("\n")
		.map((line) => line.trim())
		.filter((line) => line.length > 0);
	const verdict = parseRedirectVerdictLine(lines[lines.length - 1] ?? "");
	if (verdict === null) {
		const detail = result.stderr?.trim() || "no verdict";
		return { kind: "unavailable", reason: `harness check-deletion error: ${detail}` };
	}
	return verdict;
}

export function formatRedirectVerdict(probe: RedirectProbeResult): string {
	if (probe.kind === "unavailable") {
		return `rm redirected: unavailable (${probe.reason})`;
	}

	const { rule, reason } = probe;
	if (rule === "proven-redirect") {
		return `rm redirected: yes (proven-redirect: ${reason})`;
	}
	if (
		rule === "unproven-redirect" ||
		rule === "native-path" ||
		rule === "cmd-shell" ||
		rule === "find-primitive" ||
		rule === "no-match"
	) {
		return `rm redirected: no (${rule}: ${reason})`;
	}
	if (rule === "filter-error") {
		return `rm redirected: unavailable (filter-error: ${reason})`;
	}
	return `rm redirected: unavailable (${rule}: ${reason})`;
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
			ctx.ui.notify(
				`Outside the srt sandbox (${detection.evidence}). The full host is reachable; treat deletions, secrets, and network calls with extra care.`,
				"warning",
			);
		}
	}
}

export async function buildSandboxStatusReport(
	ctx: SandboxStatusContext,
	deps: SandboxDependencies = {},
): Promise<string> {
	const env = deps.env ?? process.env;
	const cwd = deps.cwd ?? process.cwd();
	const detection = detectSandbox(env);
	const commandPath = deps.commandPath ?? defaultCommandPath;
	const readUnproven = deps.readRegistryUnproven ?? readSafeDeleteUnproven;
	const readInject = deps.readInjectOnChange ?? readSandboxContextInjectOnChange;
	const probeRedirect = deps.probeRedirect ?? defaultProbeRedirect;

	const state = detection.sandboxed ? "sandboxed" : "unsandboxed";
	const mode = typeof ctx.mode === "string" ? ctx.mode : "unknown";
	const rmPath = commandPath("rm");
	const safeRmPath = commandPath("safe-rm");
	const ripPath = commandPath("rip");
	const utilsPath = commandPath("nucleus-utils");
	const utilsDisplay = utilsPath === "not found" ? "missing" : utilsPath;
	const unproven = readUnproven(env, cwd);
	const injectOnChange = readInject(env, cwd);
	const redirectProbe = await probeRedirect(env, cwd);
	const redirectLine = formatRedirectVerdict(redirectProbe);

	return [
		`state: ${state}`,
		`evidence: ${detection.evidence}`,
		`ctx.mode: ${mode}`,
		`rm: ${rmPath}`,
		`safe-rm present: ${presentPath(safeRmPath)}`,
		`rip present: ${presentPath(ripPath)}`,
		redirectLine,
		`nucleus-utils: ${utilsDisplay}`,
		`safe-delete.settings.unproven: ${unproven}`,
		`sandbox-context.inject-on-change: ${String(injectOnChange)}`,
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
				const report = await buildSandboxStatusReport(context, deps);
				if (context.ui && typeof context.ui.notify === "function") {
					context.ui.notify(report, "info");
				}
			},
		});
	};
}

export default createSandboxIndicatorExtension();
