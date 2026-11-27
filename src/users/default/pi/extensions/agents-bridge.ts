/**
 * Pi extension that bridges the standardized `.agents/` directory layout.
 *
 * - Discovers project-scope prompts via `resources_discover`.
 * - Injects applicable user- and project-scope instructions into the prompt
 *   via `before_agent_start`; narrow matches found during a turn use `context`.
 * - Shows a single notification summarizing all loaded resources on session start.
 *
 * Skills are auto-discovered by Pi natively (no code needed).
 */

import type {
  BeforeAgentStartEvent,
  BeforeAgentStartEventResult,
  ContextEvent,
  ContextEventResult,
  ExtensionAPI,
  ExtensionContext,
  ResourcesDiscoverEvent,
  ResourcesDiscoverResult,
  SessionStartEvent,
  ToolCallEvent,
} from "@earendil-works/pi-coding-agent";
import { readdir, readFile, stat } from "node:fs/promises";
import { join } from "node:path";
import * as process from "node:process";

/** A discovered instruction file with its scope, absolute path, and byte size. */
export interface InstructionFile {
  readonly scope: "user" | "project";
  readonly path: string;
  readonly relativePath: string;
  readonly size: number;
}

/** Frontmatter fields the bridge uses to decide when an instruction applies. */
export interface InstructionFrontmatter {
  readonly alwaysApply: boolean;
  readonly applyTo: readonly string[];
}

interface LoadedInstruction {
  readonly file: InstructionFile;
  readonly frontmatter: InstructionFrontmatter;
  readonly content: string;
}

/**
 * Collect `*.instructions.md` files from a directory.
 *
 * @param dir   Absolute path to the instructions directory.
 * @param scope Whether the directory is user-scope or project-scope.
 * @returns Sorted list of discovered instruction files. Empty array on any error.
 */
export async function collectInstructionFiles(
  dir: string,
  scope: "user" | "project",
): Promise<readonly InstructionFile[]> {
  try {
    const entries = await readdir(dir);
    const files: InstructionFile[] = [];
    for (const entry of entries) {
      if (!entry.endsWith(".instructions.md")) continue;
      const fullPath = join(dir, entry);
      try {
        const s = await stat(fullPath);
        if (s.isFile()) {
          files.push({
            scope,
            path: fullPath,
            relativePath: entry.replace(/\\/g, "/"),
            size: s.size,
          });
        }
      } catch {
        // skip unreadable entries
      }
    }
    return files.sort((a, b) => a.path.localeCompare(b.path));
  } catch {
    return [];
  }
}

function splitFrontmatter(content: string): {
  readonly frontmatter: readonly string[];
  readonly body: string;
} {
  const lines = content.split(/\r?\n/);
  if (lines[0]?.trim() !== "---") return { frontmatter: [], body: content.trim() };
  const close = lines.findIndex((line, index) => index > 0 && line.trim() === "---");
  if (close === -1) return { frontmatter: [], body: content.trim() };
  return {
    frontmatter: lines.slice(1, close),
    body: lines.slice(close + 1).join("\n").trim(),
  };
}

function stripQuotes(value: string): string {
  const trimmed = value.trim();
  const quote = trimmed.charAt(0);
  if (trimmed.length >= 2 && (quote === "\"" || quote === "'") && trimmed.endsWith(quote)) {
    return trimmed.slice(1, -1);
  }
  return trimmed;
}

function splitPatternList(value: string): readonly string[] {
  const patterns: string[] = [];
  let depth = 0;
  let start = 0;
  for (let index = 0; index < value.length; index += 1) {
    const char = value.charAt(index);
    if (char === "{") depth += 1;
    if (char === "}") depth = Math.max(0, depth - 1);
    if (char === "," && depth === 0) {
      const pattern = value.slice(start, index).trim();
      if (pattern.length > 0) patterns.push(pattern);
      start = index + 1;
    }
  }
  const last = value.slice(start).trim();
  if (last.length > 0) patterns.push(last);
  return patterns;
}

/** Read the two applicability fields from an instruction file's YAML frontmatter. */
export function parseInstructionFrontmatter(content: string): InstructionFrontmatter {
  let alwaysApply = false;
  let applyTo: readonly string[] = [];
  for (const line of splitFrontmatter(content).frontmatter) {
    const match = /^\s*(alwaysApply|applyTo)\s*:\s*(.+?)\s*$/.exec(line);
    if (!match) continue;
    const key = match[1];
    const raw = match[2];
    if (key === undefined || raw === undefined) continue;
    const value = stripQuotes(raw);
    if (key === "alwaysApply") {
      alwaysApply = value.toLowerCase() === "true";
    } else {
      applyTo = splitPatternList(value);
    }
  }
  return { alwaysApply, applyTo };
}

function escapeRegExp(value: string): string {
  return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

function compileGlob(pattern: string): RegExp {
  let source = "";
  let index = 0;
  while (index < pattern.length) {
    if (pattern.startsWith("**/", index)) {
      source += "(?:.*/)?";
      index += 3;
      continue;
    }
    if (pattern.startsWith("**", index)) {
      source += ".*";
      index += 2;
      continue;
    }
    const char = pattern.charAt(index);
    if (char === "*") {
      source += "[^/]*";
    } else if (char === "{") {
      const close = pattern.indexOf("}", index + 1);
      if (close === -1) {
        source += "\\{";
      } else {
        const alternatives = pattern.slice(index + 1, close).split(",");
        source += `(?:${alternatives.map(escapeRegExp).join("|")})`;
        index = close;
      }
    } else {
      source += escapeRegExp(char);
    }
    index += 1;
  }
  return new RegExp(`^${source}$`);
}

/** Check a repo-relative or user-root-relative path against `applyTo` globs. */
export function matchesApplyTo(
  applyTo: readonly string[] | string,
  relativePath: string,
): boolean {
  const patterns = typeof applyTo === "string" ? [applyTo] : applyTo;
  const target = relativePath.replace(/\\/g, "/").replace(/^\.\//, "");
  return patterns.some((pattern) => compileGlob(pattern.replace(/\\/g, "/")).test(target));
}

const PATH_CANDIDATE = /(?:[A-Za-z]:)?(?:\.{0,2}[\\/]|[\\/])?[A-Za-z0-9_.-]+(?:[\\/][A-Za-z0-9_.*{}-]+)+/g;

function pathsFromText(text: string): readonly string[] {
  const matches = text.match(PATH_CANDIDATE) ?? [];
  return matches.map((match) => match.replace(/\\/g, "/").replace(/[.,;:]+$/, ""));
}

function relativeToRoot(value: string, root: string): string | undefined {
  const candidate = value.replace(/\\/g, "/").replace(/^\.\//, "");
  const normalizedRoot = root.replace(/\\/g, "/").replace(/\/+$/, "");
  if (normalizedRoot.length > 0) {
    if (candidate === normalizedRoot) return "";
    if (candidate.startsWith(`${normalizedRoot}/`)) {
      return candidate.slice(normalizedRoot.length + 1);
    }
  }
  if (candidate.startsWith("/") || /^[A-Za-z]:\//.test(candidate)) return undefined;
  return candidate;
}

function pathsFromToolCall(event: ToolCallEvent): readonly string[] {
  // Tool inputs are a typed union; the shared path and command fields are read generically.
  const input = event.input as unknown as Record<string, unknown>;
  const paths: string[] = [];
  for (const field of ["path", "command"]) {
    const value = input[field];
    if (typeof value === "string") paths.push(...pathsFromText(value));
  }
  return paths;
}

async function loadInstructions(
  homeDir: string,
  cwd: string,
  isTrusted: boolean,
): Promise<readonly LoadedInstruction[]> {
  const userDir = join(homeDir, ".agents", "instructions");
  const projectDir = join(cwd, ".agents", "instructions");
  const files = [
    ...(await collectInstructionFiles(userDir, "user")),
    ...(isTrusted ? await collectInstructionFiles(projectDir, "project") : []),
  ];
  const loaded = await Promise.all(
    files.map(async (file): Promise<LoadedInstruction | undefined> => {
      try {
        const content = await readFile(file.path, "utf-8");
        const { body } = splitFrontmatter(content);
        return { file, frontmatter: parseInstructionFrontmatter(content), content: body };
      } catch {
        return undefined;
      }
    }),
  );
  return loaded.filter((item): item is LoadedInstruction => item !== undefined);
}

function formatInstructions(instructions: readonly LoadedInstruction[]): string {
  const sections: string[] = [];
  for (const [scope, heading] of [
    ["user", "## User-scope instructions (from ~/.agents/instructions/)"],
    ["project", "## Project-scope instructions (from .agents/instructions/)"],
  ] as const) {
    const bodies = instructions
      .filter((item) => item.file.scope === scope)
      .map((item) => item.content)
      .filter((body) => body.length > 0);
    if (bodies.length > 0) sections.push(`${heading}\n\n${bodies.join("\n\n")}`);
  }
  return sections.join("\n\n");
}

function isAlwaysApplicable(instruction: LoadedInstruction): boolean {
  return (
    instruction.frontmatter.alwaysApply
    || instruction.frontmatter.applyTo.some((pattern) => pattern.trim() === "**")
  );
}

function matchesCandidatePaths(
  instruction: LoadedInstruction,
  candidates: readonly string[],
  homeDir: string,
  cwd: string,
): boolean {
  const root = instruction.file.scope === "user"
    ? join(homeDir, ".agents", "instructions")
    : cwd;
  return candidates.some((candidate) => {
    const relative = relativeToRoot(candidate, root);
    return relative !== undefined
      && relative.length > 0
      && matchesApplyTo(instruction.frontmatter.applyTo, relative);
  });
}

/** Format a byte count using 1000-based SI prefixes (kB, MB, GB). */
function formatBytes(bytes: number): string {
  if (bytes < 1000) return `${bytes} B`;
  if (bytes < 1_000_000) return `${(bytes / 1000).toFixed(1)} kB`;
  if (bytes < 1_000_000_000) return `${(bytes / 1_000_000).toFixed(1)} MB`;
  return `${(bytes / 1_000_000_000).toFixed(1)} GB`;
}

/**
 * Pi extension that bridges the standardized `.agents/` directory layout.
 *
 * - Discovers project-scope prompts via `resources_discover`.
 * - Injects applicable user- and project-scope instructions into the prompt
 *   via `before_agent_start`; narrow matches found during a turn use `context`.
 * - Shows a single notification summarizing all loaded resources on session start.
 *
 * Skills are auto-discovered by Pi natively (no code needed).
 */
export default function agentsBridge(pi: ExtensionAPI): void {
  // Instruction counts and sizes are collected at session_start and read by
  // resources_discover to build a single combined notification.
  let userInstructionCount = 0;
  let userInstructionSize = 0;
  let projectInstructionCount = 0;
  let projectInstructionSize = 0;

  // Handlers share these sets for one session; a new session starts clean.
  const touchedPaths = new Set<string>();
  let injectedInstructionPaths = new Set<string>();

  pi.on(
    "session_start",
    async (_event: SessionStartEvent, ctx: ExtensionContext): Promise<void> => {
      touchedPaths.clear();
      injectedInstructionPaths = new Set<string>();

      const homeDir = process.env.HOME ?? process.env.USERPROFILE ?? "";
      if (!homeDir) return;

      const userFiles = await collectInstructionFiles(
        join(homeDir, ".agents", "instructions"),
        "user",
      );
      userInstructionCount = userFiles.length;
      userInstructionSize = userFiles.reduce((sum, f) => sum + f.size, 0);

      const projectFiles = ctx.isProjectTrusted()
        ? await collectInstructionFiles(
            join(ctx.cwd, ".agents", "instructions"),
            "project",
          )
        : [];
      projectInstructionCount = projectFiles.length;
      projectInstructionSize = projectFiles.reduce((sum, f) => sum + f.size, 0);
    },
  );

  // Register project-scope prompts for discovery and show combined notification.
  // User-scope prompts are handled via settings.json.
  pi.on(
    "resources_discover",
    async (
      event: ResourcesDiscoverEvent,
      ctx: ExtensionContext,
    ): Promise<ResourcesDiscoverResult> => {
      const projectPromptsDir = join(event.cwd, ".agents", "prompts");
      let promptCount = 0;
      let promptSize = 0;
      let discoverResult: ResourcesDiscoverResult = {};
      try {
        const s = await stat(projectPromptsDir);
        if (s.isDirectory()) {
          const entries = await readdir(projectPromptsDir);
          const mdEntries = entries.filter((e) => e.endsWith(".md"));
          promptCount = mdEntries.length;
          for (const entry of mdEntries) {
            try {
              const fs = await stat(join(projectPromptsDir, entry));
              if (fs.isFile()) promptSize += fs.size;
            } catch {
              // skip unreadable entries
            }
          }
          discoverResult = { promptPaths: [projectPromptsDir] };
        }
      } catch {
        // directory does not exist
      }

      // Show single comprehensive notification with all loaded resources.
      const parts: string[] = [];
      if (promptCount > 0) {
        parts.push(
          `${promptCount} project prompt(s) (${formatBytes(promptSize)})`,
        );
      }
      if (userInstructionCount > 0) {
        parts.push(
          `${userInstructionCount} user instruction(s) (${formatBytes(userInstructionSize)})`,
        );
      }
      if (projectInstructionCount > 0) {
        parts.push(
          `${projectInstructionCount} project instruction(s) (${formatBytes(projectInstructionSize)})`,
        );
      }
      if (parts.length > 0 && ctx.hasUI) {
        ctx.ui.notify(`Loaded ${parts.join(", ")}`, "info");
      }

      return discoverResult;
    },
  );

  // Inject applicable instructions as a prompt section, leaving Pi's prompt intact.
  pi.on(
    "before_agent_start",
    async (
      event: BeforeAgentStartEvent,
      ctx: ExtensionContext,
    ): Promise<BeforeAgentStartEventResult> => {
      const homeDir = process.env.HOME ?? process.env.USERPROFILE ?? "";
      if (!homeDir) return {};

      const instructions = await loadInstructions(
        homeDir,
        ctx.cwd,
        ctx.isProjectTrusted(),
      );
      const promptPaths = pathsFromText(event.prompt);
      const applicable = instructions.filter(
        (item) => isAlwaysApplicable(item)
          || matchesCandidatePaths(item, promptPaths, homeDir, ctx.cwd),
      );
      const section = formatInstructions(applicable);
      if (section) {
        event.systemPromptOptions.sections.agents_instructions = section;
        for (const item of applicable) {
          if (!isAlwaysApplicable(item)) injectedInstructionPaths.add(item.file.path);
        }
      }
      return {};
    },
  );

  pi.on(
    "tool_call",
    async (event: ToolCallEvent, _ctx: ExtensionContext): Promise<void> => {
      for (const path of pathsFromToolCall(event)) touchedPaths.add(path);
    },
  );

  pi.on(
    "context",
    async (event: ContextEvent, ctx: ExtensionContext): Promise<ContextEventResult> => {
      const candidates = [...touchedPaths];
      touchedPaths.clear();
      if (candidates.length === 0) return {};

      const homeDir = process.env.HOME ?? process.env.USERPROFILE ?? "";
      if (!homeDir) return {};

      const instructions = await loadInstructions(
        homeDir,
        ctx.cwd,
        ctx.isProjectTrusted(),
      );
      const newlyApplicable = instructions.filter(
        (item) => !isAlwaysApplicable(item)
          && !injectedInstructionPaths.has(item.file.path)
          && matchesCandidatePaths(item, candidates, homeDir, ctx.cwd),
      );
      if (newlyApplicable.length === 0) return {};

      for (const item of newlyApplicable) injectedInstructionPaths.add(item.file.path);
      return {
        messages: [
          ...event.messages,
          {
            role: "custom",
            customType: "agents-instructions",
            content: formatInstructions(newlyApplicable),
            display: false,
            timestamp: Date.now(),
          },
        ],
      };
    },
  );
}
