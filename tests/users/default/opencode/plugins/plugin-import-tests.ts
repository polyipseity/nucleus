import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const repoRoot = join(dirname(fileURLToPath(import.meta.url)), "../../../../..");
const plugins = [
  {
    name: "harness-notify/server.js",
    path: join(repoRoot, "src/users/default/opencode/plugins/harness-notify/server.js"),
  },
  {
    name: "prompt-tools/tui.js",
    path: join(repoRoot, "src/users/default/opencode/plugins/prompt-tools/tui.js"),
  },
] as const;

function importSpecifiers(source: string): string[] {
  const specifiers: string[] = [];
  const fromPattern = /^import\s[\s\S]*?\sfrom\s+["']([^"']+)["'];?/gm;
  for (const match of source.matchAll(fromPattern)) {
    specifiers.push(match[1]);
  }
  const sideEffectPattern = /^import\s+["']([^"']+)["'];?/gm;
  for (const match of source.matchAll(sideEffectPattern)) {
    specifiers.push(match[1]);
  }
  return [...new Set(specifiers)];
}

describe("opencode v2 plugins", () => {
  for (const plugin of plugins) {
    test(`${plugin.name} imports, exports a default function, and uses only node: specifiers`, async () => {
      const mod = await import(plugin.path);
      expect(typeof mod.default).toBe("function");

      const source = readFileSync(plugin.path, "utf8");
      const specifiers = importSpecifiers(source);
      expect(specifiers.length).toBeGreaterThan(0);
      for (const specifier of specifiers) {
        expect(specifier.startsWith("node:")).toBe(true);
      }
    });
  }
});
