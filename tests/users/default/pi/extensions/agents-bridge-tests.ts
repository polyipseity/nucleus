import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import agentsBridge, {
  collectInstructionFiles,
  matchesApplyTo,
  parseInstructionFrontmatter,
} from "../../../../../src/users/default/pi/extensions/agents-bridge.ts";

type Handler = (event: unknown, ctx: unknown) => unknown | Promise<unknown>;

interface FixturePaths {
  readonly root: string;
  readonly homeDir: string;
  readonly cwd: string;
}

interface BridgeFixture {
  readonly handlers: Readonly<Record<string, Handler>>;
  readonly sections: Record<string, string>;
  readonly sentMessages: readonly unknown[];
}

const createdRoots: string[] = [];
let originalHome: string | undefined;

beforeEach(() => {
  originalHome = process.env.HOME;
});

afterEach(() => {
  if (originalHome === undefined) {
    delete process.env.HOME;
  } else {
    process.env.HOME = originalHome;
  }
  for (const root of createdRoots.splice(0)) {
    rmSync(root, { recursive: true, force: true });
  }
});

function fixture(
  userFiles: Readonly<Record<string, string>>,
  projectFiles: Readonly<Record<string, string>>,
): FixturePaths {
  const root = mkdtempSync(join(tmpdir(), "agents-bridge-"));
  createdRoots.push(root);
  const homeDir = join(root, "home");
  const cwd = join(root, "project");
  const userDir = join(homeDir, ".agents", "instructions");
  const projectDir = join(cwd, ".agents", "instructions");
  for (const [dir, files] of [
    [userDir, userFiles],
    [projectDir, projectFiles],
  ] as const) {
    mkdirSync(dir, { recursive: true });
    for (const [name, contents] of Object.entries(files)) {
      const target = join(dir, name);
      const slash = target.lastIndexOf("/");
      if (slash === -1) throw new Error(`unexpected flat path: ${target}`);
      writeFileSync(target, contents);
    }
  }
  return { root, homeDir, cwd };
}

function instruction(frontmatter: string, body: string): string {
  return `---\ndescription: "fixture"\nname: "fixture"\n${frontmatter}\n---\n\n${body}\n`;
}

function startBridge(paths: FixturePaths): BridgeFixture {
  process.env.HOME = paths.homeDir;
  const handlers: Record<string, Handler> = {};
  const sections: Record<string, string> = {};
  const sentMessages: unknown[] = [];
  // The fake records only the extension methods the bridge calls.
  const pi = {
    on: (name: string, handler: Handler) => {
      handlers[name] = handler;
      return () => {};
    },
    sendMessage: (...args: unknown[]) => {
      sentMessages.push(args);
    },
  };
  agentsBridge(pi as unknown as Parameters<typeof agentsBridge>[0]);
  return { handlers, sections, sentMessages };
}

function context(
  trusted = true,
): { isProjectTrusted: () => boolean; cwd: string; hasUI: boolean } {
  return { isProjectTrusted: () => trusted, cwd: "", hasUI: false };
}

async function startSession(
  bridge: BridgeFixture,
  paths: FixturePaths,
  trusted = true,
): Promise<void> {
  const handler = bridge.handlers.session_start;
  if (!handler) throw new Error("session_start handler was not registered");
  await handler({}, { ...context(trusted), cwd: paths.cwd });
}

async function startTurn(
  bridge: BridgeFixture,
  paths: FixturePaths,
  prompt: string,
  trusted = true,
): Promise<string> {
  const handler = bridge.handlers.before_agent_start;
  if (!handler) throw new Error("before_agent_start handler was not registered");
  const event = {
    type: "before_agent_start",
    prompt,
    systemPrompt: "base prompt",
    systemPromptOptions: { sections: bridge.sections },
  };
  await handler(event, { ...context(trusted), cwd: paths.cwd });
  return bridge.sections.agents_instructions ?? "";
}

async function callReadTool(bridge: BridgeFixture, relativePath: string): Promise<void> {
  const handler = bridge.handlers.tool_call;
  if (!handler) throw new Error("tool_call handler was not registered");
  await handler(
    { type: "tool_call", toolName: "read", toolCallId: "call-1", input: { path: relativePath } },
    {},
  );
}

async function runContext(
  bridge: BridgeFixture,
  paths: FixturePaths,
  trusted = true,
): Promise<unknown> {
  const handler = bridge.handlers.context;
  if (!handler) throw new Error("context handler was not registered");
  return handler(
    { type: "context", messages: [] },
    { ...context(trusted), cwd: paths.cwd },
  );
}

async function injectedTexts(
  bridge: BridgeFixture,
  paths: FixturePaths,
  trusted = true,
): Promise<readonly string[]> {
  const result: unknown = await runContext(bridge, paths, trusted);
  if (typeof result !== "object" || result === null || !("messages" in result)) {
    return [];
  }
  const messages = (result as { messages: readonly unknown[] }).messages;
  return messages.flatMap((message) => {
    if (typeof message !== "object" || message === null || !("content" in message)) return [];
    const content = (message as { content: unknown }).content;
    if (typeof content !== "string") return [];
    return [content];
  });
}

describe("agents bridge instruction discovery", () => {
  test("collectInstructionFiles skips reference and plain Markdown files", async () => {
    const paths = fixture(
      {
        "always.instructions.md": instruction('alwaysApply: true\napplyTo: "**"', "always body"),
        "harness-adapters.reference.md": "reference body",
        "README.md": "plain body",
      },
      {},
    );

    const files = await collectInstructionFiles(
      join(paths.homeDir, ".agents", "instructions"),
      "user",
    );

    expect(files.map((file) => file.relativePath)).toEqual(["always.instructions.md"]);
    expect(files[0]?.scope).toBe("user");
  });

  test("parseInstructionFrontmatter reads only alwaysApply and applyTo", () => {
    const parsed = parseInstructionFrontmatter(
      instruction(
        'alwaysApply: true\napplyTo: "src/**/*.nix, scripts/**/*.{sh,ps1}"',
        "body",
      ),
    );

    expect(parsed.alwaysApply).toBe(true);
    expect(parsed.applyTo).toEqual(["src/**/*.nix", "scripts/**/*.{sh,ps1}"]);
  });
});

describe("agents bridge applyTo glob matching", () => {
  test("matchesApplyTo supports recursive, single-level, and brace globs", () => {
    expect(matchesApplyTo(["**"], "any/nested/file.md")).toBe(true);
    expect(matchesApplyTo(["src/**/*.nix"], "src/foo.nix")).toBe(true);
    expect(matchesApplyTo(["src/**/*.nix"], "src/nested/foo.nix")).toBe(true);
    expect(matchesApplyTo(["src/**/*.nix"], "README.md")).toBe(false);
    expect(matchesApplyTo(["scripts/**/*.{sh,ps1}"], "scripts/check.sh")).toBe(true);
    expect(matchesApplyTo(["scripts/**/*.{sh,ps1}"], "scripts/check.ps1")).toBe(true);
    expect(matchesApplyTo(["scripts/**/*.{sh,ps1}"], "scripts/check.py")).toBe(false);
  });
});

describe("agents bridge prompt-time injection", () => {
  test("injects alwaysApply and applyTo ** from user and project scopes", async () => {
    const paths = fixture(
      {
        "user-always.instructions.md": instruction('alwaysApply: true\napplyTo: "**"', "user always body"),
        "user-narrow.instructions.md": instruction('alwaysApply: false\napplyTo: "src/**/*.nix"', "user narrow body"),
      },
      {
        "project-all.instructions.md": instruction('alwaysApply: false\napplyTo: "**"', "project all body"),
        "project-narrow.instructions.md": instruction('alwaysApply: false\napplyTo: "src/**/*.nix"', "project narrow body"),
      },
    );
    const bridge = startBridge(paths);
    await startSession(bridge, paths);

    const section = await startTurn(bridge, paths, "review the documentation");

    expect(section).toContain("user always body");
    expect(section).toContain("project all body");
    expect(section).not.toContain("user narrow body");
    expect(section).not.toContain("project narrow body");
    expect(section).not.toContain("alwaysApply");
  });

  test("injects a narrow instruction when the prompt names a matching path", async () => {
    const paths = fixture(
      {},
      {
        "nix.instructions.md": instruction('alwaysApply: false\napplyTo: "src/**/*.nix"', "nix body"),
      },
    );
    const bridge = startBridge(paths);
    await startSession(bridge, paths);

    const section = await startTurn(bridge, paths, "edit src/foo.nix");

    expect(section).toContain("nix body");
  });
});

describe("agents bridge Windows-style paths", () => {
  test("injects a narrow instruction when the prompt uses backslash separators", async () => {
    const paths = fixture(
      {},
      {
        "nix.instructions.md": instruction('alwaysApply: false\napplyTo: "src/**/*.nix"', "backslash nix body"),
      },
    );
    const bridge = startBridge(paths);
    await startSession(bridge, paths);

    const section = await startTurn(bridge, paths, "edit src\\foo.nix");

    expect(section).toContain("backslash nix body");
  });

  test("injects a narrow instruction after a drive-prefixed absolute tool path", async () => {
    const root = mkdtempSync(join(tmpdir(), "agents-bridge-win-"));
    createdRoots.push(root);
    const projectDir = join(root, "C:", "repo", ".agents", "instructions");
    mkdirSync(projectDir, { recursive: true });
    writeFileSync(
      join(projectDir, "nix.instructions.md"),
      instruction('alwaysApply: false\napplyTo: "src/**/*.nix"', "drive nix body"),
    );
    const paths: FixturePaths = { root, homeDir: join(root, "home"), cwd: "C:/repo" };
    const originalCwd = process.cwd();
    try {
      // A drive-prefixed path is relative on POSIX, so resolve it from the fixture root.
      process.chdir(root);
      const bridge = startBridge(paths);
      await startSession(bridge, paths);
      await startTurn(bridge, paths, "review the documentation");
      await callReadTool(bridge, "C:\\repo\\src\\foo.nix");

      const texts = await injectedTexts(bridge, paths);

      expect(texts.join("\n")).toContain("drive nix body");
    } finally {
      process.chdir(originalCwd);
    }
  });
});

describe("agents bridge untrusted projects", () => {
  test("keeps project instructions out of prompt sections and context messages", async () => {
    const paths = fixture(
      {
        "user-always.instructions.md": instruction('alwaysApply: true\napplyTo: "**"', "user always body"),
        "user-narrow.instructions.md": instruction('alwaysApply: false\napplyTo: "src/**/*.nix"', "user narrow body"),
      },
      {
        "project-always.instructions.md": instruction('alwaysApply: true\napplyTo: "**"', "project always body"),
        "project-narrow.instructions.md": instruction('alwaysApply: false\napplyTo: "src/**/*.nix"', "project narrow body"),
      },
    );
    const bridge = startBridge(paths);
    await startSession(bridge, paths, false);
    const section = await startTurn(bridge, paths, "review the documentation", false);

    await callReadTool(bridge, "src/foo.nix");
    const texts = await injectedTexts(bridge, paths, false);

    expect(section).toContain("user always body");
    expect(section).not.toContain("project always body");
    expect(section).not.toContain("project narrow body");
    expect(texts.join("\n")).toContain("user narrow body");
    expect(texts.join("\n")).not.toContain("project always body");
    expect(texts.join("\n")).not.toContain("project narrow body");
  });

  test("returns a hidden custom message for newly applicable instructions", async () => {
    const paths = fixture(
      {},
      {
        "nix.instructions.md": instruction('alwaysApply: false\napplyTo: "src/**/*.nix"', "narrow body"),
      },
    );
    const bridge = startBridge(paths);
    await startSession(bridge, paths);
    await startTurn(bridge, paths, "review the documentation");

    await callReadTool(bridge, "src/foo.nix");
    const result: unknown = await runContext(bridge, paths);
    const messages = (result as { messages?: readonly unknown[] }).messages ?? [];

    expect(messages).toHaveLength(1);
    expect(messages[0]).toMatchObject({
      role: "custom",
      customType: "agents-instructions",
      display: false,
    });
    expect((messages[0] as { content?: string }).content).toContain("narrow body");
  });

  test("before_agent_start leaves the base systemPrompt untouched", async () => {
    const paths = fixture(
      {
        "user-always.instructions.md": instruction('alwaysApply: true\napplyTo: "**"', "user body"),
      },
      {},
    );
    const bridge = startBridge(paths);
    await startSession(bridge, paths);
    const handler = bridge.handlers.before_agent_start;
    if (!handler) throw new Error("before_agent_start handler was not registered");
    const event = {
      type: "before_agent_start",
      prompt: "review the documentation",
      systemPrompt: "base prompt",
      systemPromptOptions: { sections: bridge.sections },
    };

    const result: unknown = await handler(event, { ...context(), cwd: paths.cwd });

    expect(event.systemPrompt).toBe("base prompt");
    expect((result as { systemPrompt?: string }).systemPrompt).toBeUndefined();
    expect(bridge.sections.agents_instructions).toContain("user body");
  });
});

describe("agents bridge tool-path injection", () => {
  test("injects a narrow instruction once after a tool touches a matching path", async () => {
    const paths = fixture(
      {
        "user-nix.instructions.md": instruction('alwaysApply: false\napplyTo: "src/**/*.nix"', "user nix body"),
      },
      {
        "project-nix.instructions.md": instruction('alwaysApply: false\napplyTo: "src/**/*.nix"', "project nix body"),
      },
    );
    const bridge = startBridge(paths);
    await startSession(bridge, paths);
    await startTurn(bridge, paths, "review the documentation");

    await callReadTool(bridge, "src/foo.nix");
    const first = await injectedTexts(bridge, paths);
    const second = await injectedTexts(bridge, paths);

    expect(first.join("\n")).toContain("user nix body");
    expect(first.join("\n")).toContain("project nix body");
    expect(second).toEqual([]);
    expect(bridge.sentMessages).toEqual([]);
  });
});
