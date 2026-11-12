import { beforeEach, describe, expect, test } from "bun:test";
import { mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import sandboxIndicator, {
	SANDBOX_LABEL,
	STATUS_KEY,
	UNSANDBOXED_LABEL,
	buildSandboxStatusReport,
	createSandboxIndicatorExtension,
	detectSandbox,
	readSafeDeleteUnproven,
	resetSandboxWarningForTests,
	type SandboxStatusContext,
} from "../../../../../src/users/default/pi/extensions/sandbox-indicator.ts";

type Handler = (event: unknown, ctx?: unknown) => void | Promise<void>;
type CommandHandler = (args: string, ctx: unknown) => void | Promise<void>;

interface Registered {
	readonly events: Record<string, Handler>;
	readonly command?: { description: string; handler: CommandHandler };
}

function registerExtension(env: NodeJS.ProcessEnv): Registered {
	const events: Record<string, Handler> = {};
	let command: { description: string; handler: CommandHandler } | undefined;
	const pi = {
		on: (name: string, handler: Handler) => {
			events[name] = handler;
			return () => {};
		},
		registerCommand: (name: string, options: { description: string; handler: CommandHandler }) => {
			if (name === "sandbox-status") {
				command = { description: options.description, handler: options.handler };
			}
		},
	};
	createSandboxIndicatorExtension({ env })(pi as unknown as Parameters<typeof sandboxIndicator>[0]);
	return { events, command };
}

function makeContext(options: { hasUI?: boolean; mode?: string } = {}): {
	ctx: SandboxStatusContext;
	statuses: Array<[string, string | undefined]>;
	notifications: Array<[string, string]>;
} {
	const statuses: Array<[string, string | undefined]> = [];
	const notifications: Array<[string, string]> = [];
	const ctx: SandboxStatusContext = {
		hasUI: options.hasUI,
		mode: options.mode,
		ui: {
			setStatus: (key, value) => statuses.push([key, value]),
			notify: (message, type) => notifications.push([message, type ?? "info"]),
		},
	};
	return { ctx, statuses, notifications };
}

describe("detectSandbox", () => {
	test("marker 1 is sandboxed with exact label and evidence", () => {
		const result = detectSandbox({ SANDBOX_RUNTIME: "1" });
		expect(result.sandboxed).toBe(true);
		expect(result.label).toBe(SANDBOX_LABEL);
		expect(result.label).toBe("SANDBOX: srt");
		expect(result.evidence).toBe("SANDBOX_RUNTIME=1");
	});

	test("unset is unsandboxed with exact label and evidence", () => {
		const result = detectSandbox({});
		expect(result.sandboxed).toBe(false);
		expect(result.label).toBe(UNSANDBOXED_LABEL);
		expect(result.label).toBe("SANDBOX: NONE (unsandboxed)");
		expect(result.evidence).toBe("SANDBOX_RUNTIME unset");
	});

	test("empty string is unsandboxed with exact label and evidence", () => {
		const result = detectSandbox({ SANDBOX_RUNTIME: "" });
		expect(result.sandboxed).toBe(false);
		expect(result.label).toBe(UNSANDBOXED_LABEL);
		expect(result.evidence).toBe("SANDBOX_RUNTIME empty string");
	});

	test("0 is unsandboxed with exact label and evidence", () => {
		const result = detectSandbox({ SANDBOX_RUNTIME: "0" });
		expect(result.sandboxed).toBe(false);
		expect(result.label).toBe(UNSANDBOXED_LABEL);
		expect(result.evidence).toBe("SANDBOX_RUNTIME=0 (false-like)");
	});

	test("false is unsandboxed with exact label and evidence (case-insensitively)", () => {
		for (const value of ["false", "FALSE", "False"]) {
			const result = detectSandbox({ SANDBOX_RUNTIME: value });
			expect(result.sandboxed).toBe(false);
			expect(result.label).toBe(UNSANDBOXED_LABEL);
			expect(result.evidence).toBe(`SANDBOX_RUNTIME=${value} (false-like)`);
		}
	});

	test("bogus non-false value is sandboxed with exact label and evidence", () => {
		const result = detectSandbox({ SANDBOX_RUNTIME: "bogus" });
		expect(result.sandboxed).toBe(true);
		expect(result.label).toBe(SANDBOX_LABEL);
		expect(result.evidence).toBe("SANDBOX_RUNTIME=bogus");
	});
});

describe("sandbox status lifecycle", () => {
	beforeEach(() => {
		resetSandboxWarningForTests();
	});

	test("session_start sets status when sandboxed and does not warn", () => {
		const { events } = registerExtension({ SANDBOX_RUNTIME: "1" });
		const { ctx, statuses, notifications } = makeContext({ hasUI: true, mode: "interactive" });

		events.session_start?.({}, ctx);

		expect(statuses).toEqual([[STATUS_KEY, SANDBOX_LABEL]]);
		expect(notifications).toEqual([]);
	});

	test("session_compact sets status when sandboxed and does not warn", () => {
		const { events } = registerExtension({ SANDBOX_RUNTIME: "1" });
		const { ctx, statuses, notifications } = makeContext({ hasUI: true, mode: "interactive" });

		events.session_compact?.({}, ctx);

		expect(statuses).toEqual([[STATUS_KEY, SANDBOX_LABEL]]);
		expect(notifications).toEqual([]);
	});

	test("session_start warns once per process when unsandboxed and hasUI", () => {
		const { events } = registerExtension({});
		const first = makeContext({ hasUI: true, mode: "interactive" });
		const second = makeContext({ hasUI: true, mode: "interactive" });

		events.session_start?.({}, first.ctx);
		events.session_start?.({}, second.ctx);

		expect(first.statuses).toEqual([[STATUS_KEY, UNSANDBOXED_LABEL]]);
		expect(second.statuses).toEqual([[STATUS_KEY, UNSANDBOXED_LABEL]]);
		expect(first.notifications).toEqual([["Running unsandboxed (SANDBOX_RUNTIME not set).", "warning"]]);
		expect(second.notifications).toEqual([]);
	});

	test("session_compact does not warn again after session_start warned in same process", () => {
		const { events } = registerExtension({});
		const start = makeContext({ hasUI: true, mode: "interactive" });
		const compact = makeContext({ hasUI: true, mode: "interactive" });

		events.session_start?.({}, start.ctx);
		events.session_compact?.({}, compact.ctx);

		expect(start.notifications).toEqual([["Running unsandboxed (SANDBOX_RUNTIME not set).", "warning"]]);
		expect(compact.notifications).toEqual([]);
		expect(compact.statuses).toEqual([[STATUS_KEY, UNSANDBOXED_LABEL]]);
	});

	test("unsandboxed with no UI sets status but emits no warning", () => {
		const { events } = registerExtension({});
		const noUI = makeContext({ hasUI: false, mode: "print" });
		const withUI = makeContext({ hasUI: true, mode: "interactive" });

		events.session_start?.({}, noUI.ctx);
		events.session_compact?.({}, withUI.ctx);

		expect(noUI.statuses).toEqual([[STATUS_KEY, UNSANDBOXED_LABEL]]);
		expect(noUI.notifications).toEqual([]);
		expect(withUI.notifications).toEqual([["Running unsandboxed (SANDBOX_RUNTIME not set).", "warning"]]);
	});

	test("sandboxed never warns even with UI", () => {
		const { events } = registerExtension({ SANDBOX_RUNTIME: "1" });
		const { ctx, notifications } = makeContext({ hasUI: true, mode: "interactive" });

		events.session_start?.({}, ctx);
		events.session_compact?.({}, ctx);

		expect(notifications).toEqual([]);
	});

	test("session_shutdown clears the status key", () => {
		const { events } = registerExtension({ SANDBOX_RUNTIME: "1" });
		const { ctx, statuses } = makeContext({ hasUI: true, mode: "interactive" });

		events.session_start?.({}, ctx);
		events.session_shutdown?.({}, ctx);

		expect(statuses).toEqual([
			[STATUS_KEY, SANDBOX_LABEL],
			[STATUS_KEY, undefined],
		]);
	});
});

describe("readSafeDeleteUnproven", () => {
	test("reads from NUCLEUS_REPO_ROOT candidate first", () => {
		const root = mkdtempSync(join(tmpdir(), "sandbox-indicator-"));
		const path = join(root, "src", "modules", "configs");
		Bun.spawnSync(["mkdir", "-p", path]);
		const registryPath = join(path, "harness-filters.json");
		writeFileSync(registryPath, JSON.stringify({ filters: [{ id: "safe-delete", settings: { unproven: "ask" } }] }));

		expect(readSafeDeleteUnproven({ NUCLEUS_REPO_ROOT: root }, "/nonexistent")).toBe("ask");
	});

	test("falls back to cwd candidate", () => {
		const cwd = mkdtempSync(join(tmpdir(), "sandbox-indicator-cwd-"));
		const path = join(cwd, "src", "modules", "configs");
		Bun.spawnSync(["mkdir", "-p", path]);
		writeFileSync(join(path, "harness-filters.json"), JSON.stringify({ filters: [{ id: "safe-delete", settings: { unproven: "deny" } }] }));

		expect(readSafeDeleteUnproven({}, cwd)).toBe("deny");
	});

	test("returns unavailable when filter or file is missing", () => {
		const cwd = mkdtempSync(join(tmpdir(), "sandbox-indicator-miss-"));
		expect(readSafeDeleteUnproven({}, cwd)).toBe("unavailable");
	});
});

describe("buildSandboxStatusReport and /sandbox-status", () => {
	beforeEach(() => {
		resetSandboxWarningForTests();
	});

	test("includes state, evidence, mode, rm, tools, and registry value when sandboxed", () => {
		const report = buildSandboxStatusReport(
			{ mode: "interactive" },
			{
				env: { SANDBOX_RUNTIME: "1" },
				cwd: "/tmp",
				commandPath: (command) => (command === "rm" ? "/usr/bin/rm" : "not found"),
				commandExists: (command) => command === "shell-safe-rm",
				readRegistryUnproven: () => "ask",
			},
		);

		expect(report).toContain("state: sandboxed");
		expect(report).toContain("evidence: SANDBOX_RUNTIME=1");
		expect(report).toContain("ctx.mode: interactive");
		expect(report).toContain("rm: /usr/bin/rm");
		expect(report).toContain("shell-safe-rm present: true");
		expect(report).toContain("rip present: false");
		expect(report).toContain("safe-delete.settings.unproven: ask");
	});

	test("includes state, evidence, mode, rm, tools, and registry value when unsandboxed", () => {
		const report = buildSandboxStatusReport(
			{ mode: "print" },
			{
				env: {},
				cwd: "/tmp",
				commandPath: (command) => (command === "rm" ? "not found" : "not found"),
				commandExists: (command) => command === "rip",
				readRegistryUnproven: () => "unavailable",
			},
		);

		expect(report).toContain("state: unsandboxed");
		expect(report).toContain("evidence: SANDBOX_RUNTIME unset");
		expect(report).toContain("ctx.mode: print");
		expect(report).toContain("rm: not found");
		expect(report).toContain("shell-safe-rm present: false");
		expect(report).toContain("rip present: true");
		expect(report).toContain("safe-delete.settings.unproven: unavailable");
	});

	test("/sandbox-status command prints report via notify in both sandboxed and unsandboxed cases", async () => {
		const sandboxed = registerExtension({ SANDBOX_RUNTIME: "1" });
		const sandboxedCtx = makeContext({ hasUI: true, mode: "interactive" });
		const sandboxedExt = createSandboxIndicatorExtension({
			env: { SANDBOX_RUNTIME: "1" },
			cwd: "/tmp",
			commandPath: () => "/bin/rm",
			commandExists: (command) => command === "shell-safe-rm",
			readRegistryUnproven: () => "ask",
		});
		const events: Record<string, Handler> = {};
		let command: CommandHandler | undefined;
		sandboxedExt({
			on: (name: string, handler: Handler) => {
				events[name] = handler;
				return () => {};
			},
			registerCommand: (_name: string, options: { handler: CommandHandler }) => {
				command = options.handler;
			},
		} as unknown as Parameters<typeof sandboxIndicator>[0]);

		await command?.("", sandboxedCtx.ctx);
		expect(sandboxedCtx.notifications).toHaveLength(1);
		expect(sandboxedCtx.notifications[0][1]).toBe("info");
		expect(sandboxedCtx.notifications[0][0]).toContain("state: sandboxed");
		expect(sandboxedCtx.notifications[0][0]).toContain("evidence: SANDBOX_RUNTIME=1");
		expect(sandboxedCtx.notifications[0][0]).toContain("ctx.mode: interactive");
		expect(sandboxedCtx.notifications[0][0]).toContain("rm: /bin/rm");
		expect(sandboxedCtx.notifications[0][0]).toContain("shell-safe-rm present: true");
		expect(sandboxedCtx.notifications[0][0]).toContain("rip present: false");
		expect(sandboxedCtx.notifications[0][0]).toContain("safe-delete.settings.unproven: ask");

		resetSandboxWarningForTests();
		const unsandboxedCtx = makeContext({ hasUI: true, mode: "json" });
		const unsandboxedExt = createSandboxIndicatorExtension({
			env: {},
			cwd: "/tmp",
			commandPath: () => "not found",
			commandExists: (command) => command === "rip",
			readRegistryUnproven: () => "deny",
		});
		let unsandboxedCommand: CommandHandler | undefined;
		unsandboxedExt({
			on: (_name: string, _handler: Handler) => () => {},
			registerCommand: (_name: string, options: { handler: CommandHandler }) => {
				unsandboxedCommand = options.handler;
			},
		} as unknown as Parameters<typeof sandboxIndicator>[0]);

		await unsandboxedCommand?.("", unsandboxedCtx.ctx);
		expect(unsandboxedCtx.notifications).toHaveLength(1);
		expect(unsandboxedCtx.notifications[0][1]).toBe("info");
		expect(unsandboxedCtx.notifications[0][0]).toContain("state: unsandboxed");
		expect(unsandboxedCtx.notifications[0][0]).toContain("evidence: SANDBOX_RUNTIME unset");
		expect(unsandboxedCtx.notifications[0][0]).toContain("ctx.mode: json");
		expect(unsandboxedCtx.notifications[0][0]).toContain("rm: not found");
		expect(unsandboxedCtx.notifications[0][0]).toContain("shell-safe-rm present: false");
		expect(unsandboxedCtx.notifications[0][0]).toContain("rip present: true");
		expect(unsandboxedCtx.notifications[0][0]).toContain("safe-delete.settings.unproven: deny");
		expect(sandboxed.command?.description).toBe("Show sandbox state and deletion-safety tooling status");
	});
});

describe("readSafeDeleteUnproven real registry", () => {
	test("reads the repo harness-filters.json safe-delete unproven value", () => {
		const repoRoot = process.env.NUCLEUS_REPO_ROOT ?? process.cwd();
		const registryPath = join(repoRoot, "src/modules/configs/harness-filters.json");
		const parsed = JSON.parse(readFileSync(registryPath, "utf8")) as { filters?: Array<{ id?: string; settings?: { unproven?: string } }> };
		const expected = parsed.filters?.find((entry) => entry.id === "safe-delete")?.settings?.unproven ?? "unavailable";
		expect(readSafeDeleteUnproven({ NUCLEUS_REPO_ROOT: repoRoot }, repoRoot)).toBe(expected);
	});
});
