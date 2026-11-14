import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { spawn } from "node:child_process";
import { join } from "node:path";
import createSafeDeleteExtension, {
	buildPayload,
	createSafeDeleteExtension as createExtension,
	hasDeletionWord,
	runHarnessFilter,
	spawnHarnessFilter,
	type RunnerOptions,
	type SafeDeleteUi,
	type SpawnFn,
	type SpawnResult,
} from "../../../../../src/users/default/pi/extensions/safe-delete.ts";

const REPO_ROOT = process.cwd();
const RUNNER_PATH = join(REPO_ROOT, "src/scripts/notify/harness-filter.sh");
const ESC = String.fromCharCode(27);

const originalNoColor = process.env.NO_COLOR;
const originalTerm = process.env.TERM;

// The status expectations below pin the plain form, so each test starts with
// NO_COLOR present; the tone tests opt out explicitly and restore afterwards.
beforeEach(() => {
	process.env.NO_COLOR = "";
});

afterEach(() => {
	if (originalNoColor === undefined) {
		delete process.env.NO_COLOR;
	} else {
		process.env.NO_COLOR = originalNoColor;
	}
	if (originalTerm === undefined) {
		delete process.env.TERM;
	} else {
		process.env.TERM = originalTerm;
	}
});

function allowColor(): () => void {
	const savedNoColor = process.env.NO_COLOR;
	const savedTerm = process.env.TERM;
	delete process.env.NO_COLOR;
	delete process.env.TERM;
	return () => {
		if (savedNoColor === undefined) {
			delete process.env.NO_COLOR;
		} else {
			process.env.NO_COLOR = savedNoColor;
		}
		if (savedTerm === undefined) {
			delete process.env.TERM;
		} else {
			process.env.TERM = savedTerm;
		}
	};
}

type ToolCallEvent = { toolName: string; input: { command?: unknown } };
type ToolCallHandler = (
	event: ToolCallEvent,
	ctx: { hasUI: boolean; ui: SafeDeleteUi },
) => Promise<{ block?: boolean; reason?: string } | undefined>;

type SpawnCall = {
	command: string;
	args: readonly string[];
	stdin: string;
	timeoutMs: number;
};

function loadExtension(options: RunnerOptions = {}): ToolCallHandler {
	let handler: ToolCallHandler | undefined;
	const pi = {
		on: (name: string, registered: unknown) => {
			if (name === "tool_call") {
				handler = registered as ToolCallHandler;
			}
			return () => {};
		},
	};
	createExtension(options)(pi as unknown as Parameters<typeof createSafeDeleteExtension>[0]);
	if (handler === undefined) {
		throw new Error("safe-delete registered no tool_call handler");
	}
	return handler;
}

function fakeSpawn(verdict: "allow" | "ask" | "deny", calls?: SpawnCall[]): SpawnFn {
	return async (command, args, stdin, timeoutMs): Promise<SpawnResult> => {
		calls?.push({ command, args, stdin, timeoutMs });
		return {
			code: 0,
			signal: null,
			stdout: `${verdict}\n`,
			stderr: "",
			timedOut: false,
		};
	};
}

function realRunnerOptions(): RunnerOptions {
	return { runnerCommand: RUNNER_PATH, runnerArgs: ["pi"], timeoutMs: 30_000 };
}

function spawnWithRepoRoot(): SpawnFn {
	return async (command, args, stdin, timeoutMs): Promise<SpawnResult> => {
		return await new Promise<SpawnResult>((resolve) => {
			let settled = false;
			let timedOut = false;
			let timer: ReturnType<typeof setTimeout> | undefined;
			const child = spawn(command, [...args], {
				stdio: ["pipe", "pipe", "pipe"],
				env: { ...process.env, NUCLEUS_REPO_ROOT: REPO_ROOT },
			});
			const stdoutChunks: string[] = [];
			const stderrChunks: string[] = [];
			const onData = (target: string[], chunk: Buffer | string): void => {
				target.push(String(chunk));
			};
			child.stdout.on("data", (chunk) => onData(stdoutChunks, chunk));
			child.stderr.on("data", (chunk) => onData(stderrChunks, chunk));
			const finish = (base: Omit<SpawnResult, "stdout" | "stderr">): void => {
				if (settled) {
					return;
				}
				settled = true;
				if (timer !== undefined) {
					clearTimeout(timer);
				}
				resolve({ ...base, stdout: stdoutChunks.join(""), stderr: stderrChunks.join("") });
			};
			child.on("error", (error: Error) => {
				finish({ code: null, signal: null, timedOut, error: error.message });
			});
			child.on("close", (code, signal) => {
				finish({ code, signal, timedOut });
			});
			if (timeoutMs > 0) {
				timer = setTimeout(() => {
					timedOut = true;
					child.kill("SIGKILL");
				}, timeoutMs);
			}
			child.stdin.on("error", () => {});
			child.stdin.end(stdin);
		});
	};
}

describe("safe-delete pre-filter and payload", () => {
	test("hasDeletionWord matches deletion words case-insensitively and misses ordinary commands", () => {
		expect(hasDeletionWord("rm file.txt")).toBe(true);
		expect(hasDeletionWord("Remove-Item foo")).toBe(true);
		expect(hasDeletionWord("ls -la")).toBe(false);
		expect(hasDeletionWord("printf ok")).toBe(false);
	});

	test("buildPayload emits the harness hook shape", () => {
		const command = "sh -c '/bin/rm /tmp/x'";
		expect(JSON.parse(buildPayload(command))).toEqual({
			tool_name: "bash",
			tool_input: { command },
		});
	});

	test("pre-filter short-circuits non-bash tools and commands without deletion words", async () => {
		const calls: SpawnCall[] = [];
		const handler = loadExtension({ spawnFn: fakeSpawn("deny", calls) });

		await expect(
			handler({ toolName: "read", input: { command: "rm -rf /" } }, { hasUI: false, ui: { hasUI: false } }),
		).resolves.toBeUndefined();
		await expect(
			handler({ toolName: "bash", input: { command: "ls -la" } }, { hasUI: false, ui: { hasUI: false } }),
		).resolves.toBeUndefined();

		expect(calls).toEqual([]);
	});
});

describe("safe-delete verdict mapping", () => {
	test("deny blocks and reports status set then cleared", async () => {
		const status: Array<[string, string | undefined]> = [];
		const handler = loadExtension({ spawnFn: fakeSpawn("deny") });
		const ui: SafeDeleteUi = {
			hasUI: false,
			setStatus: (key, value) => status.push([key, value]),
		};

		const result = await handler(
			{ toolName: "bash", input: { command: "rm file.txt" } },
			{ hasUI: false, ui },
		);

		expect(result).toEqual({
			block: true,
			reason: "Blocked by the safe-delete filter (deny). Use shell-safe-rm or rip2 instead.",
		});
		expect(status).toEqual([
			["safe-delete", "safe-delete: blocked"],
			["safe-delete", undefined],
		]);
	});

	test("deny sets a red blocked status when color is allowed", async () => {
		const restore = allowColor();
		try {
			const status: Array<[string, string | undefined]> = [];
			const handler = loadExtension({ spawnFn: fakeSpawn("deny") });
			const ui: SafeDeleteUi = {
				hasUI: false,
				setStatus: (key, value) => status.push([key, value]),
			};

			await handler(
				{ toolName: "bash", input: { command: "rm file.txt" } },
				{ hasUI: false, ui },
			);

			expect(status).toEqual([
				["safe-delete", `${ESC}[31msafe-delete: blocked${ESC}[0m`],
				["safe-delete", undefined],
			]);
		} finally {
			restore();
		}
	});

	test("ask sets a yellow confirmation status when color is allowed", async () => {
		const restore = allowColor();
		try {
			const status: Array<[string, string | undefined]> = [];
			const handler = loadExtension({ spawnFn: fakeSpawn("ask") });
			const ui: SafeDeleteUi = {
				hasUI: false,
				setStatus: (key, value) => status.push([key, value]),
			};

			await handler(
				{ toolName: "bash", input: { command: "rm file.txt" } },
				{ hasUI: false, ui },
			);

			expect(status).toEqual([
				["safe-delete", `${ESC}[33msafe-delete: confirmation required${ESC}[0m`],
				["safe-delete", undefined],
			]);
		} finally {
			restore();
		}
	});

	test("ask blocks without UI, reports no confirmation was possible, and clears status", async () => {
		const status: Array<[string, string | undefined]> = [];
		const handler = loadExtension({ spawnFn: fakeSpawn("ask") });
		const ui: SafeDeleteUi = {
			hasUI: false,
			setStatus: (key, value) => status.push([key, value]),
		};

		const result = await handler(
			{ toolName: "bash", input: { command: "rm file.txt" } },
			{ hasUI: false, ui },
		);

		expect(result).toEqual({
			block: true,
			reason:
				"Blocked by the safe-delete filter (ask) and no confirmation UI is available. Use shell-safe-rm or rip2 instead.",
		});
		expect(status).toEqual([
			["safe-delete", "safe-delete: confirmation required"],
			["safe-delete", undefined],
		]);
	});

	test("ask with UI confirm true allows and clears status on settle", async () => {
		const status: Array<[string, string | undefined]> = [];
		const confirms: Array<[string, string]> = [];
		const handler = loadExtension({ spawnFn: fakeSpawn("ask") });
		const ui: SafeDeleteUi = {
			hasUI: true,
			confirm: async (title, message) => {
				confirms.push([title, message]);
				return true;
			},
			setStatus: (key, value) => status.push([key, value]),
		};

		const result = await handler(
			{ toolName: "bash", input: { command: "rm file.txt" } },
			{ hasUI: true, ui },
		);

		expect(result).toBeUndefined();
		expect(confirms).toHaveLength(1);
		expect(confirms[0]?.[0]).toBe("Safe-delete filter requires confirmation");
		expect(confirms[0]?.[1]).toContain("rm file.txt");
		expect(status).toEqual([
			["safe-delete", "safe-delete: confirmation required"],
			["safe-delete", undefined],
		]);
	});

	test("ask with UI confirm false blocks and clears status on settle", async () => {
		const status: Array<[string, string | undefined]> = [];
		const handler = loadExtension({ spawnFn: fakeSpawn("ask") });
		const ui: SafeDeleteUi = {
			hasUI: true,
			confirm: async () => false,
			setStatus: (key, value) => status.push([key, value]),
		};

		const result = await handler(
			{ toolName: "bash", input: { command: "rm file.txt" } },
			{ hasUI: true, ui },
		);

		expect(result).toEqual({ block: true, reason: "Blocked by safe-delete extension" });
		expect(status).toEqual([
			["safe-delete", "safe-delete: confirmation required"],
			["safe-delete", undefined],
		]);
	});

	test("allow passes through without status changes", async () => {
		const status: Array<[string, string | undefined]> = [];
		const handler = loadExtension({ spawnFn: fakeSpawn("allow") });
		const ui: SafeDeleteUi = {
			hasUI: false,
			setStatus: (key, value) => status.push([key, value]),
		};

		const result = await handler(
			{ toolName: "bash", input: { command: "rm file.txt" } },
			{ hasUI: false, ui },
		);

		expect(result).toBeUndefined();
		expect(status).toEqual([]);
	});

	test("runner payload, command, and args are forwarded to the spawn seam", async () => {
		const calls: SpawnCall[] = [];
		const handler = loadExtension({
			runnerCommand: "/custom/harness-filter",
			runnerArgs: ["pi"],
			timeoutMs: 4321,
			spawnFn: fakeSpawn("allow", calls),
		});

		await handler(
			{ toolName: "bash", input: { command: "rm -f /tmp/x" } },
			{ hasUI: false, ui: { hasUI: false } },
		);

		expect(calls).toHaveLength(1);
		expect(calls[0]).toEqual({
			command: "/custom/harness-filter",
			args: ["pi"],
			stdin: JSON.stringify({ tool_name: "bash", tool_input: { command: "rm -f /tmp/x" } }),
			timeoutMs: 4321,
		});
	});
});

describe("safe-delete real policy path regressions", () => {
	test("quoted native path blocks through the shared policy (G1)", async () => {
		const verdict = await runHarnessFilter('sh -c "/bin/rm /tmp/safe-delete-g1"', {
			...realRunnerOptions(),
			spawnFn: spawnWithRepoRoot(),
		});
		expect(verdict.decision).toBe("deny");

		const handler = loadExtension({ ...realRunnerOptions(), spawnFn: spawnWithRepoRoot() });
		const result = await handler(
			{ toolName: "bash", input: { command: 'sh -c "/bin/rm /tmp/safe-delete-g1"' } },
			{ hasUI: false, ui: { hasUI: false } },
		);
		expect(result?.block).toBe(true);
	});

	test("reading a file named rm after a shell command is allowed (G2)", async () => {
		const command = "zsh -c 'printf x' ; cat ~/.local/bin/rm";
		const verdict = await runHarnessFilter(command, {
			...realRunnerOptions(),
			spawnFn: spawnWithRepoRoot(),
		});
		expect(verdict.decision).toBe("allow");

		const handler = loadExtension({ ...realRunnerOptions(), spawnFn: spawnWithRepoRoot() });
		const result = await handler(
			{ toolName: "bash", input: { command } },
			{ hasUI: false, ui: { hasUI: false } },
		);
		expect(result).toBeUndefined();
	});

	test("a proven plain rm redirect is allowed by the shared policy path", async () => {
		const verdict = await runHarnessFilter("rm /tmp/safe-delete-proven", {
			...realRunnerOptions(),
			spawnFn: spawnWithRepoRoot(),
		});
		expect(verdict.decision).toBe("allow");
	});
});
