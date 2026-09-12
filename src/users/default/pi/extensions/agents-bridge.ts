/**
 * Pi extension that bridges the standardized `.agents/` directory layout.
 *
 * - Discovers project-scope prompts via `resources_discover`.
 * - Injects user-scope and project-scope instructions into the system prompt
 *   via `before_agent_start`.
 * - Shows a single notification summarizing all loaded resources on session start.
 *
 * Skills are auto-discovered by Pi natively (no code needed).
 */

import type {
  BeforeAgentStartEvent,
  BeforeAgentStartEventResult,
  ExtensionAPI,
  ExtensionContext,
  ResourcesDiscoverEvent,
  ResourcesDiscoverResult,
  SessionStartEvent,
} from "@earendil-works/pi-coding-agent";
import { readdir, readFile, stat } from "node:fs/promises";
import { join } from "node:path";
import * as process from "node:process";

/** A discovered instruction file with its scope, absolute path, and byte size. */
interface InstructionFile {
  scope: "user" | "project";
  path: string;
  size: number;
}

/**
 * Collect `.md` instruction files from a directory.
 *
 * @param dir   Absolute path to the instructions directory.
 * @param scope Whether the directory is user-scope or project-scope.
 * @returns Sorted list of discovered instruction files. Empty array on any error.
 */
async function collectInstructionFiles(
  dir: string,
  scope: "user" | "project",
): Promise<InstructionFile[]> {
  try {
    const entries = await readdir(dir);
    const files: InstructionFile[] = [];
    for (const entry of entries) {
      if (!entry.endsWith(".md")) continue;
      const fullPath = join(dir, entry);
      try {
        const s = await stat(fullPath);
        if (s.isFile()) {
          files.push({ scope, path: fullPath, size: s.size });
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

/**
 * Read multiple files concurrently, returning only successfully read contents.
 *
 * @param paths Absolute file paths to read.
 * @returns Array of file contents (unreadable files silently excluded).
 */
async function readFiles(paths: string[]): Promise<string[]> {
  const results = await Promise.all(
    paths.map(async (p) => {
      try {
        return await readFile(p, "utf-8");
      } catch {
        return null;
      }
    }),
  );
  return results.filter((c): c is string => c !== null);
}

/**
 * Read and concatenate instruction files from user and project scopes.
 *
 * User-scope files are always included. Project-scope files are only
 * included when `isTrusted` is true.
 *
 * @param homeDir   The user's home directory (e.g. `$HOME`).
 * @param cwd       The current working directory.
 * @param isTrusted Whether project-local trust is active.
 * @returns Concatenated instruction sections, or empty string if none found.
 */
async function readInstructions(
  homeDir: string,
  cwd: string,
  isTrusted: boolean,
): Promise<string> {
  const userDir = join(homeDir, ".agents", "instructions");
  const projectDir = join(cwd, ".agents", "instructions");

  const userFiles = await collectInstructionFiles(userDir, "user");
  const projectFiles = isTrusted
    ? await collectInstructionFiles(projectDir, "project")
    : [];

  const allFiles = [...userFiles, ...projectFiles];
  if (allFiles.length === 0) return "";

  const sections: string[] = [];

  if (userFiles.length > 0) {
    const valid = await readFiles(userFiles.map((f) => f.path));
    if (valid.length > 0) {
      sections.push(
        `## User-scope instructions (from ~/.agents/instructions/)\n\n${valid.join("\n\n")}`,
      );
    }
  }

  if (projectFiles.length > 0) {
    const valid = await readFiles(projectFiles.map((f) => f.path));
    if (valid.length > 0) {
      sections.push(
        `## Project-scope instructions (from .agents/instructions/)\n\n${valid.join("\n\n")}`,
      );
    }
  }

  return sections.join("\n\n");
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
 * - Injects user-scope and project-scope instructions into the system prompt
 *   via `before_agent_start`.
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

  pi.on(
    "session_start",
    async (_event: SessionStartEvent, ctx: ExtensionContext): Promise<void> => {
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

  // Inject instructions from both user and project scope into the system prompt.
  pi.on(
    "before_agent_start",
    async (
      event: BeforeAgentStartEvent,
      ctx: ExtensionContext,
    ): Promise<BeforeAgentStartEventResult> => {
      const homeDir = process.env.HOME ?? process.env.USERPROFILE ?? "";
      if (!homeDir) return {};

      const instructions = await readInstructions(
        homeDir,
        ctx.cwd,
        ctx.isProjectTrusted(),
      );
      if (!instructions) return {};

      return {
        systemPrompt: `${event.systemPrompt}\n\n${instructions}`,
      };
    },
  );
}
