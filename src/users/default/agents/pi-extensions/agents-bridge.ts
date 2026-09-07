// agents-bridge.ts — Pi coding agent bridge for the standardized .agents/ directory.
//
// This extension makes Pi recognize both user-scope (~/.agents/) and
// project-scope (./.agents/) agent files.
//
// What is handled natively by Pi (no code needed):
//   - ~/.agents/skills/  → auto-discovered (user scope)
//   - .agents/skills/    → auto-discovered (project scope, cwd + ancestors)
//
// What this extension handles:
//   - Project-scope prompts (.agents/prompts/) via resources_discover
//   - Instructions from both scopes (~/.agents/instructions/ and .agents/instructions/)
//     injected into the system prompt via before_agent_start

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { readdir, readFile, stat } from "node:fs/promises";
import { join } from "node:path";

interface InstructionFile {
  scope: "user" | "project";
  path: string;
}

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
          files.push({ scope, path: fullPath });
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
    const contents = await Promise.all(
      userFiles.map(async (f) => {
        try {
          return await readFile(f.path, "utf-8");
        } catch {
          return null;
        }
      }),
    );
    const valid = contents.filter((c): c is string => c !== null);
    if (valid.length > 0) {
      sections.push(
        `## User-scope instructions (from ~/.agents/instructions/)\n\n${valid.join("\n\n")}`,
      );
    }
  }

  if (projectFiles.length > 0) {
    const contents = await Promise.all(
      projectFiles.map(async (f) => {
        try {
          return await readFile(f.path, "utf-8");
        } catch {
          return null;
        }
      }),
    );
    const valid = contents.filter((c): c is string => c !== null);
    if (valid.length > 0) {
      sections.push(
        `## Project-scope instructions (from .agents/instructions/)\n\n${valid.join("\n\n")}`,
      );
    }
  }

  return sections.join("\n\n");
}

export default function (pi: ExtensionAPI) {
  // Collect instruction counts at session start for the notification.
  let userInstructionCount = 0;
  let projectInstructionCount = 0;

  pi.on("session_start", async (_event, ctx) => {
    const homeDir = process.env.HOME ?? process.env.USERPROFILE ?? "";
    if (!homeDir) return;

    const userFiles = await collectInstructionFiles(
      join(homeDir, ".agents", "instructions"),
      "user",
    );
    userInstructionCount = userFiles.length;

    const projectFiles = ctx.isProjectTrusted()
      ? await collectInstructionFiles(join(ctx.cwd, ".agents", "instructions"), "project")
      : [];
    projectInstructionCount = projectFiles.length;
  });

  // Register project-scope prompts for discovery and show combined notification.
  // User-scope prompts are handled via settings.json.
  pi.on("resources_discover", async (event, ctx) => {
    const projectPromptsDir = join(event.cwd, ".agents", "prompts");
    let promptCount = 0;
    try {
      const s = await stat(projectPromptsDir);
      if (s.isDirectory()) {
        const entries = await readdir(projectPromptsDir);
        promptCount = entries.filter((e) => e.endsWith(".md")).length;
        return { promptPaths: [projectPromptsDir] };
      }
    } catch {
      // directory does not exist
    }

    // Show single comprehensive notification with all loaded resources.
    const parts: string[] = [];
    if (promptCount > 0) {
      parts.push(`${promptCount} project prompts`);
    }
    if (userInstructionCount > 0) {
      parts.push(`${userInstructionCount} user instructions`);
    }
    if (projectInstructionCount > 0) {
      parts.push(`${projectInstructionCount} project instructions`);
    }
    if (parts.length > 0 && ctx.hasUI) {
      ctx.ui.notify(`Loaded ${parts.join(", ")}`, "info");
    }

    return {};
  });

  // Inject instructions from both user and project scope into the system prompt.
  pi.on("before_agent_start", async (event, ctx) => {
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
  });
}
