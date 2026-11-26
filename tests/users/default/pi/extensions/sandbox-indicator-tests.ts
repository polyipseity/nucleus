import { beforeEach, describe, expect, test } from "bun:test";
import { chmodSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import sandboxIndicator, {
	SANDBOX_LABEL,
	STATUS_KEY,
	UNSANDBOXED_LABEL,
	buildSandboxStatusReport,
	createSandboxIndicatorExtension,
	defaultProbeRedirect,
	detectSandbox,
	formatRedirectVerdict,
	readSafeDeleteUnproven,
	readSandboxContextInjectOnChange,
	resetSandboxWarningForTests,
	type SandboxStatusContext,
} from "../../../../../src/users/default/pi/extensions/sandbox-indicator.ts";

const ESC = String.fromCharCode(27);

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
		expect(result.label).toBe("sandbox: srt");
		expect(result.evidence).toBe("SANDBOX_RUNTIME=1");
	});

	test("unset is unsandboxed with exact label and evidence", () => {
		const result = detectSandbox({});
		expect(result.sandboxed).toBe(false);
		expect(result.label).toBe(UNSANDBOXED_LABEL);
		expect(result.label).toBe("sandbox: none");
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
		const { events } = registerExtension({ NO_COLOR: "" });
		const first = makeContext({ hasUI: true, mode: "interactive" });
		const second = makeContext({ hasUI: true, mode: "interactive" });

		events.session_start?.({}, first.ctx);
		events.session_start?.({}, second.ctx);

		expect(first.statuses).toEqual([[STATUS_KEY, UNSANDBOXED_LABEL]]);
		expect(second.statuses).toEqual([[STATUS_KEY, UNSANDBOXED_LABEL]]);
		expect(first.notifications).toEqual([["Outside the srt sandbox (SANDBOX_RUNTIME unset). The full host is reachable; treat deletions, secrets, and network calls with extra care.", "warning"]]);
		expect(second.notifications).toEqual([]);
	});

	test("session_compact does not warn again after session_start warned in same process", () => {
		const { events } = registerExtension({ NO_COLOR: "" });
		const start = makeContext({ hasUI: true, mode: "interactive" });
		const compact = makeContext({ hasUI: true, mode: "interactive" });

		events.session_start?.({}, start.ctx);
		events.session_compact?.({}, compact.ctx);

		expect(start.notifications).toEqual([["Outside the srt sandbox (SANDBOX_RUNTIME unset). The full host is reachable; treat deletions, secrets, and network calls with extra care.", "warning"]]);
		expect(compact.notifications).toEqual([]);
		expect(compact.statuses).toEqual([[STATUS_KEY, UNSANDBOXED_LABEL]]);
	});

	test("unsandboxed with no UI sets status but emits no warning", () => {
		const { events } = registerExtension({ NO_COLOR: "" });
		const noUI = makeContext({ hasUI: false, mode: "print" });
		const withUI = makeContext({ hasUI: true, mode: "interactive" });

		events.session_start?.({}, noUI.ctx);
		events.session_compact?.({}, withUI.ctx);

		expect(noUI.statuses).toEqual([[STATUS_KEY, UNSANDBOXED_LABEL]]);
		expect(noUI.notifications).toEqual([]);
		expect(withUI.notifications).toEqual([["Outside the srt sandbox (SANDBOX_RUNTIME unset). The full host is reachable; treat deletions, secrets, and network calls with extra care.", "warning"]]);
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

describe("sandbox status tone", () => {
	beforeEach(() => {
		resetSandboxWarningForTests();
	});

	test("unsandboxed label is warning yellow with tone token in both footer variants", () => {
		const { events } = registerExtension({});
		const start = makeContext({ hasUI: false, mode: "interactive" });
		const compact = makeContext({ hasUI: false, mode: "interactive" });

		events.session_start?.({}, start.ctx);
		events.session_compact?.({}, compact.ctx);

		expect(start.statuses).toEqual([[STATUS_KEY, `${ESC}[33msandbox: none${ESC}[0m`]]);
		expect(compact.statuses).toEqual([[STATUS_KEY, `${ESC}[33msandbox: none${ESC}[0m`]]);
	});

	test("TERM=dumb keeps the unsandboxed label plain", () => {
		const { events } = registerExtension({ TERM: "dumb" });
		const { ctx, statuses } = makeContext({ hasUI: false, mode: "interactive" });

		events.session_start?.({}, ctx);

		expect(statuses).toEqual([[STATUS_KEY, "sandbox: none"]]);
	});

	test("sandboxed label is sandbox: srt in both footer variants", () => {
		const { events } = registerExtension({ SANDBOX_RUNTIME: "1" });
		const start = makeContext({ hasUI: false, mode: "interactive" });
		const compact = makeContext({ hasUI: false, mode: "interactive" });

		events.session_start?.({}, start.ctx);
		events.session_compact?.({}, compact.ctx);

		expect(start.statuses).toEqual([[STATUS_KEY, "sandbox: srt"]]);
		expect(compact.statuses).toEqual([[STATUS_KEY, "sandbox: srt"]]);
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

describe("readSandboxContextInjectOnChange", () => {
	test("defaults to true when config is absent or unconfigured", () => {
		const home = mkdtempSync(join(tmpdir(), "sandbox-indicator-home-"));
		expect(readSandboxContextInjectOnChange({ HOME: home }, "/tmp")).toBe(true);
	});

	test("reads configured boolean value", () => {
		const home = mkdtempSync(join(tmpdir(), "sandbox-indicator-home-"));
		const configDir = join(home, ".local", "state", "nucleus");
		Bun.spawnSync(["mkdir", "-p", configDir]);
		writeFileSync(
			join(configDir, "config.json"),
			JSON.stringify({ "sandbox-context": { "inject-on-change": false } }),
		);
		expect(readSandboxContextInjectOnChange({ HOME: home }, "/tmp")).toBe(false);
	});
});

describe("formatRedirectVerdict", () => {
	test("renders proven redirect as yes", () => {
		expect(
			formatRedirectVerdict({
				kind: "verdict",
				decision: "allow",
				rule: "proven-redirect",
				reason: "deletion command: rm resolves to the home-manager safe-delete wrapper at /x",
			}),
		).toBe(
			"rm redirected: yes (proven-redirect: deletion command: rm resolves to the home-manager safe-delete wrapper at /x)",
		);
	});

	test("renders unproven and native-path as no", () => {
		expect(
			formatRedirectVerdict({
				kind: "verdict",
				decision: "ask",
				rule: "unproven-redirect",
				reason: "rm does not resolve on PATH",
			}),
		).toBe("rm redirected: no (unproven-redirect: rm does not resolve on PATH)");
		expect(
			formatRedirectVerdict({
				kind: "verdict",
				decision: "deny",
				rule: "native-path",
				reason: "native rm bypasses safe-delete protection. Use safe-rm or rip2 instead.",
			}),
		).toBe("rm redirected: no (native-path: native rm bypasses safe-delete protection. Use safe-rm or rip2 instead.)");
	});

	test("renders filter errors as unavailable", () => {
		expect(
			formatRedirectVerdict({
				kind: "verdict",
				decision: "ask",
				rule: "filter-error",
				reason: "settings are not valid JSON",
			}),
		).toBe("rm redirected: unavailable (filter-error: settings are not valid JSON)");
	});
});

describe("buildSandboxStatusReport and /sandbox-status", () => {
	beforeEach(() => {
		resetSandboxWarningForTests();
	});

	test("reports resolved paths, proven redirect, and config values when sandboxed", async () => {
		const report = await buildSandboxStatusReport(
			{ mode: "interactive" },
			{
				env: { SANDBOX_RUNTIME: "1" },
				cwd: "/tmp",
				commandPath: (command) => {
					if (command === "rm") return "/usr/bin/rm";
					if (command === "safe-rm") return "not found";
					if (command === "rip") return "/opt/homebrew/bin/rip";
					if (command === "nucleus-utils") return "/opt/nucleus/bin/nucleus-utils";
					return "not found";
				},
				readRegistryUnproven: () => "ask",
				readInjectOnChange: () => false,
				probeRedirect: () => ({
					kind: "verdict",
					decision: "allow",
					rule: "proven-redirect",
					reason: "deletion command: rm resolves to the deployed rip shim at /usr/bin/rm",
				}),
			},
		);

		expect(report).toContain("state: sandboxed");
		expect(report).toContain("evidence: SANDBOX_RUNTIME=1");
		expect(report).toContain("ctx.mode: interactive");
		expect(report).toContain("rm: /usr/bin/rm");
		expect(report).toContain("safe-rm present: absent");
		expect(report).toContain("rip present: /opt/homebrew/bin/rip");
		expect(report).toContain(
			"rm redirected: yes (proven-redirect: deletion command: rm resolves to the deployed rip shim at /usr/bin/rm)",
		);
		expect(report).toContain("nucleus-utils: /opt/nucleus/bin/nucleus-utils");
		expect(report).toContain("safe-delete.settings.unproven: ask");
		expect(report).toContain("sandbox-context.inject-on-change: false");
	});

	test("reports safe-rm absent with a proven redirect", async () => {
		const report = await buildSandboxStatusReport(
			{ mode: "interactive" },
			{
				env: { SANDBOX_RUNTIME: "1" },
				cwd: "/tmp",
				commandPath: (command) => {
					if (command === "safe-rm") return "not found";
					if (command === "rip") return "not found";
					if (command === "rm") return "/usr/bin/rm";
					return "/usr/bin/nucleus-utils";
				},
				readRegistryUnproven: () => "ask",
				readInjectOnChange: () => true,
				probeRedirect: () => ({
					kind: "verdict",
					decision: "allow",
					rule: "proven-redirect",
					reason: "deletion command: rm resolves to the deployed rip shim at /usr/bin/rm, whose hash matches the shim manifest",
				}),
			},
		);

		expect(report).toContain("safe-rm present: absent");
		expect(report).toContain("rip present: absent");
		expect(report).toContain("rm redirected: yes (proven-redirect:");
	});

	test("reports both present with an unproven redirect", async () => {
		const report = await buildSandboxStatusReport(
			{ mode: "interactive" },
			{
				env: {},
				cwd: "/tmp",
				commandPath: (command) => {
					if (command === "safe-rm") return "/home/user/.bun/bin/safe-rm";
					if (command === "rip") return "/nix/store/abc/bin/rip";
					if (command === "rm") return "/usr/bin/rm";
					if (command === "nucleus-utils") return "/usr/bin/nucleus-utils";
					return "not found";
				},
				readRegistryUnproven: () => "deny",
				readInjectOnChange: () => true,
				probeRedirect: () => ({
					kind: "verdict",
					decision: "ask",
					rule: "unproven-redirect",
					reason: "rm does not resolve on PATH, so it is treated as not redirected and the harness prompts",
				}),
			},
		);

		expect(report).toContain("state: unsandboxed");
		expect(report).toContain("evidence: SANDBOX_RUNTIME unset");
		expect(report).toContain("safe-rm present: /home/user/.bun/bin/safe-rm");
		expect(report).toContain("rip present: /nix/store/abc/bin/rip");
		expect(report).toContain("rm redirected: no (unproven-redirect:");
		expect(report).toContain("safe-delete.settings.unproven: deny");
		expect(report).toContain("sandbox-context.inject-on-change: true");
	});

	test("reports unavailable when harness check-deletion cannot be run because command is missing", async () => {
		const report = await buildSandboxStatusReport(
			{ mode: "print" },
			{
				env: {},
				cwd: "/tmp",
				commandPath: () => "not found",
				readRegistryUnproven: () => "unavailable",
				readInjectOnChange: () => true,
				probeRedirect: () => ({ kind: "unavailable", reason: "nucleus-utils not on PATH" }),
			},
		);

		expect(report).toContain("rm redirected: unavailable (nucleus-utils not on PATH)");
		expect(report).toContain("nucleus-utils: missing");
	});

	test("/sandbox-status command prints report via notify", async () => {
		const registered = registerExtension({ SANDBOX_RUNTIME: "1" });
		expect(registered.command?.description).toBe("Show sandbox state and deletion-safety tooling status");

		const context = makeContext({ hasUI: true, mode: "interactive" });
		const ext = createSandboxIndicatorExtension({
			env: { SANDBOX_RUNTIME: "1" },
			cwd: "/tmp",
			commandPath: (command) => {
				if (command === "nucleus-utils") return "/nucleus/bin/nucleus-utils";
				if (command === "safe-rm") return "/bin/safe-rm";
				if (command === "rip") return "not found";
				return "/bin/rm";
			},
			readRegistryUnproven: () => "ask",
			readInjectOnChange: () => true,
			probeRedirect: () => ({
				kind: "verdict",
				decision: "allow",
				rule: "proven-redirect",
				reason: "deletion command: rm resolves to the home-manager safe-delete wrapper at /bin/rm",
			}),
		});

		let command: CommandHandler | undefined;
		ext({
			on: (_name: string, _handler: Handler) => () => {},
			registerCommand: (_name: string, options: { handler: CommandHandler }) => {
				command = options.handler;
			},
		} as unknown as Parameters<typeof sandboxIndicator>[0]);

		await command?.("", context.ctx);
		expect(context.notifications).toHaveLength(1);
		expect(context.notifications[0][1]).toBe("info");
		const report = context.notifications[0][0];
		expect(report).toContain("state: sandboxed");
		expect(report).toContain("safe-rm present: /bin/safe-rm");
		expect(report).toContain("rip present: absent");
		expect(report).toContain("rm redirected: yes (proven-redirect:");
		expect(report).toContain("safe-delete.settings.unproven: ask");
		expect(report).toContain("sandbox-context.inject-on-change: true");
	});
});

describe("readSafeDeleteUnproven real registry", () => {
	test("reads the repo harness-filters.json safe-delete unproven value", () => {
		const repoRoot = process.env.NUCLEUS_REPO_ROOT ?? process.cwd();
		const registryPath = join(repoRoot, "src/modules/configs/harness-filters.json");
		const parsed = JSON.parse(readFileSync(registryPath, "utf8")) as {
			filters?: Array<{ id?: string; settings?: { unproven?: string } }>;
		};
		const expected =
			parsed.filters?.find((entry) => entry.id === "safe-delete")?.settings?.unproven ?? "unavailable";
		expect(readSafeDeleteUnproven({ NUCLEUS_REPO_ROOT: repoRoot }, repoRoot)).toBe(expected);
	});
});

describe("defaultProbeRedirect spawn path", () => {
	test("runs a fake nucleus-utils harness check-deletion CLI without settings.json", () => {
		const binDir = mkdtempSync(join(tmpdir(), "sandbox-indicator-cli-"));
		const scriptPath = join(binDir, "nucleus-utils");
		writeFileSync(
			scriptPath,
			[
				"#!/bin/sh",
				'if [ "$1" = "harness" ] && [ "$2" = "check-deletion" ] && [ "$3" = "--command" ]; then',
				"  printf 'allow\\tproven-redirect\\tdeletion command: rm resolves to the fake safe-delete wrapper at /fake/bin/rm\\n'",
				"  exit 0",
				"fi",
				"echo unexpected args >&2",
				"exit 1",
				"",
			].join("\n"),
		);
		chmodSync(scriptPath, 0o755);

		const result = defaultProbeRedirect(
			{ PATH: `${binDir}:${process.env.PATH ?? ""}` },
			process.cwd(),
		);

		expect(result).toEqual({
			kind: "verdict",
			decision: "allow",
			rule: "proven-redirect",
			reason: "deletion command: rm resolves to the fake safe-delete wrapper at /fake/bin/rm",
		});
	});
});
