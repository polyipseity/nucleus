// Cases for the context-window extension: pure parsing and precedence, the
// deterministic serializer, file round-trips against a temp directory so the
// session command's writes are exercised without touching ~/.pi, the footer
// snapshot plus the lines it renders, and the footer wiring the default export
// installs when a fake host delivers session_start and model_select events.

import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { existsSync, lstatSync, linkSync, mkdtempSync, readFileSync, statSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
// Type-only: bun erases it, so the suite keeps resolving with no runtime deps.
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import contextCap, {
  applyToFiles,
  buildFooterSnapshot,
  effectiveWindow,
  footerCwd,
  footerFormatting,
  formatFullStatus,
  formatScopeStatus,
  formatTokens,
  noteWrittenCap,
  parseCommand,
  providerWindow,
  readCap,
  renderFooterLines,
  resetWrittenCap,
  resolveWindow,
  serialize,
  setGlobalCap,
  setModelWindow,
  syncModelWindow,
  type ActiveModel,
  type FilePaths,
  type FooterSnapshot,
  type FooterSnapshotSource,
  type FooterTheme,
  type Json,
  type ModelCatalog,
} from "../../../../../src/users/default/pi/extensions/context-cap.ts";

const active: ActiveModel = { provider: "opencode-go", id: "glm-5.1" };

const catalog: ModelCatalog = {
  getAll: () => [
    { provider: "anthropic", id: "claude-sonnet-5" },
    { provider: "opencode-go", id: "glm-5.1" },
    { provider: "opencode-go", id: "mimo-v2.6-flash" },
  ],
};

function tempPaths(seed: { settings?: string; models?: string } = {}): FilePaths {
  const dir = mkdtempSync(join(tmpdir(), "context-cap-"));
  const paths: FilePaths = { settings: join(dir, "settings.json"), models: join(dir, "models.json") };
  if (seed.settings !== undefined) writeFileSync(paths.settings, seed.settings, "utf8");
  if (seed.models !== undefined) writeFileSync(paths.models, seed.models, "utf8");
  return paths;
}

describe("parseCommand", () => {
  test("bare and all query the full status block", () => {
    expect(parseCommand("", active)).toEqual({ kind: "status", scope: "all" });
    expect(parseCommand("all", active)).toEqual({ kind: "status", scope: "all" });
  });

  test("single-scope queries use the active target when omitted", () => {
    expect(parseCommand("session", active)).toEqual({ kind: "status", scope: "session" });
    expect(parseCommand("global", active)).toEqual({ kind: "status", scope: "global" });
    expect(parseCommand("model", active)).toEqual({
      kind: "status",
      scope: "model",
      provider: "opencode-go",
      model: "glm-5.1",
    });
    expect(parseCommand("provider", active)).toEqual({
      kind: "status",
      scope: "provider",
      provider: "opencode-go",
    });
  });

  test("model and provider queries accept an explicit target", () => {
    expect(parseCommand("model anthropic/claude-sonnet-5", active)).toEqual({
      kind: "status",
      scope: "model",
      provider: "anthropic",
      model: "claude-sonnet-5",
    });
    expect(parseCommand("provider opencode-go", active)).toEqual({
      kind: "status",
      scope: "provider",
      provider: "opencode-go",
    });
  });

  test("set uses scope-after-value with session as the default scope", () => {
    expect(parseCommand("200000", active)).toEqual({ kind: "set", scope: "session", value: 200000 });
    expect(parseCommand("200000 session", active)).toEqual({ kind: "set", scope: "session", value: 200000 });
    expect(parseCommand("256000 global", active)).toEqual({ kind: "set", scope: "global", value: 256000 });
  });

  test("model and provider set accept an explicit target", () => {
    expect(parseCommand("500000 model", active)).toEqual({
      kind: "set",
      scope: "model",
      value: 500000,
      provider: "opencode-go",
      model: "glm-5.1",
    });
    expect(parseCommand("500000 model anthropic/claude-sonnet-5", active)).toEqual({
      kind: "set",
      scope: "model",
      value: 500000,
      provider: "anthropic",
      model: "claude-sonnet-5",
    });
    expect(parseCommand("200000 provider", active)).toEqual({
      kind: "set",
      scope: "provider",
      value: 200000,
      provider: "opencode-go",
    });
    expect(parseCommand("200000 provider opencode-go", active)).toEqual({
      kind: "set",
      scope: "provider",
      value: 200000,
      provider: "opencode-go",
    });
  });

  test("clear uses default or any negative value with the same scope and target forms", () => {
    expect(parseCommand("default", active)).toEqual({ kind: "clear", scope: "session" });
    expect(parseCommand("-1", active)).toEqual({ kind: "clear", scope: "session" });
    expect(parseCommand("default session", active)).toEqual({ kind: "clear", scope: "session" });
    expect(parseCommand("-1 global", active)).toEqual({ kind: "clear", scope: "global" });
    expect(parseCommand("default model", active)).toEqual({
      kind: "clear",
      scope: "model",
      provider: "opencode-go",
      model: "glm-5.1",
    });
    expect(parseCommand("-5 model anthropic/claude-sonnet-5", active)).toEqual({
      kind: "clear",
      scope: "model",
      provider: "anthropic",
      model: "claude-sonnet-5",
    });
    expect(parseCommand("default provider opencode-go", active)).toEqual({
      kind: "clear",
      scope: "provider",
      provider: "opencode-go",
    });
    expect(parseCommand("-2 provider", active)).toEqual({
      kind: "clear",
      scope: "provider",
      provider: "opencode-go",
    });
  });

  test("rejects malformed forms and the old scope-first set grammar", () => {
    for (const input of [
      "0",
      "session 0",
      "global 256000",
      "global default",
      "nonsense",
      "effective",
      "all extra",
      "session extra",
      "model 900000 500000",
      "provider 200000 300000",
      "200000 extra",
      "default extra",
      "-1 extra",
      "500000 model provider/",
      "model /foo",
      "default model /bar",
      "500000 provider a/b",
      "-0",
      "-0 model provider/",
    ]) {
      expect(parseCommand(input, active).kind).toBe("error");
    }
  });

  test("splits a model target on the first slash only", () => {
    expect(parseCommand("model a/b/c", active)).toEqual({
      kind: "status",
      scope: "model",
      provider: "a",
      model: "b/c",
    });
    expect(parseCommand("500000 model a/b/c", active)).toEqual({
      kind: "set",
      scope: "model",
      value: 500000,
      provider: "a",
      model: "b/c",
    });
  });

  test("non-positive windows error while negative values still clear", () => {
    for (const input of ["0", "-0", "007"]) {
      expect(parseCommand(input, active)).toEqual({
        kind: "error",
        message: expect.stringContaining("context window must be a positive integer"),
      });
    }
    expect(parseCommand("-1", active)).toEqual({ kind: "clear", scope: "session" });
  });
});

describe("resolveWindow", () => {
  test("session wins over everything", () => {
    expect(resolveWindow({ baseline: 1000000, session: 300000, explicit: 900000, cap: 256000 })).toEqual({
      window: 300000,
      source: "session",
    });
  });

  test("an explicit model window wins over the ceiling", () => {
    expect(resolveWindow({ baseline: 1000000, session: null, explicit: 900000, cap: 256000 })).toEqual({
      window: 900000,
      source: "model",
    });
  });

  test("the ceiling applies only when the baseline is bigger", () => {
    expect(resolveWindow({ baseline: 1000000, session: null, explicit: null, cap: 256000 })).toEqual({
      window: 256000,
      source: "global",
    });
    expect(resolveWindow({ baseline: 100000, session: null, explicit: null, cap: 256000 })).toEqual({
      window: 100000,
      source: "native",
    });
  });

  test("no ceiling means the baseline", () => {
    expect(resolveWindow({ baseline: 200000, session: null, explicit: null, cap: null })).toEqual({
      window: 200000,
      source: "native",
    });
  });
});

describe("readCap", () => {
  test("accepts only positive finite numbers", () => {
    expect(readCap({ contextWindowCap: 256000 })).toBe(256000);
    for (const value of [0, -1, Number.POSITIVE_INFINITY, "256000", null]) {
      expect(readCap({ contextWindowCap: value })).toBeNull();
    }
    expect(readCap(null)).toBeNull();
  });
});

describe("setGlobalCap", () => {
  test("sets and removes the key", () => {
    const settings: Json = { $schema: "https://example.invalid/settings.json" };
    setGlobalCap(settings, 256000);
    expect(settings.contextWindowCap).toBe(256000);
    setGlobalCap(settings, null);
    expect("contextWindowCap" in settings).toBe(false);
    expect(settings.$schema).toBe("https://example.invalid/settings.json");
  });
});

describe("setModelWindow", () => {
  test("creates the provider and override containers it needs", () => {
    const models: Json = {};
    setModelWindow(models, "anthropic", "claude-sonnet-5", 500000);
    expect(models).toEqual({
      providers: { anthropic: { modelOverrides: { "claude-sonnet-5": { contextWindow: 500000 } } } },
    });
  });

  test("keeps other override fields and sibling models", () => {
    const models: Json = {
      providers: {
        anthropic: {
          modelOverrides: {
            "claude-sonnet-5": { maxTokens: 64000, contextWindow: 1 },
            "claude-opus-4": { contextWindow: 900000 },
          },
        },
      },
    };
    setModelWindow(models, "anthropic", "claude-sonnet-5", 500000);
    expect(models).toEqual({
      providers: {
        anthropic: {
          modelOverrides: {
            "claude-sonnet-5": { maxTokens: 64000, contextWindow: 500000 },
            "claude-opus-4": { contextWindow: 900000 },
          },
        },
      },
    });
  });

  test("clear prunes only what it emptied", () => {
    const models: Json = {
      providers: {
        anthropic: {
          apiKey: "env:ANTHROPIC_API_KEY",
          modelOverrides: { "claude-sonnet-5": { contextWindow: 500000 } },
        },
        empty: { modelOverrides: { x: { contextWindow: 1 } } },
      },
    };
    setModelWindow(models, "anthropic", "claude-sonnet-5", null);
    setModelWindow(models, "empty", "x", null);
    expect(models).toEqual({ providers: { anthropic: { apiKey: "env:ANTHROPIC_API_KEY" } } });
  });
});

describe("serialize", () => {
  test("sorts keys, indents two spaces, and ends with one newline", () => {
    expect(serialize({ zeta: 1, alpha: { beta: true }, list: [{ b: 2, a: 1 }] })).toBe(
      '{\n  "alpha": {\n    "beta": true\n  },\n  "list": [\n    {\n      "a": 1,\n      "b": 2\n    }\n  ],\n  "zeta": 1\n}\n',
    );
  });
});

describe("providerWindow", () => {
  test("reports a uniform provider override and count", () => {
    const models: Json = {
      providers: {
        "opencode-go": {
          modelOverrides: {
            "glm-5.1": { contextWindow: 200000 },
            "mimo-v2.6-flash": { contextWindow: 200000 },
          },
        },
      },
    };
    expect(providerWindow(catalog, "opencode-go", models)).toEqual({ value: 200000, count: 2 });
  });

  test("reports mixed when provider models differ or are partly unset", () => {
    const models: Json = {
      providers: {
        "opencode-go": {
          modelOverrides: {
            "glm-5.1": { contextWindow: 200000 },
          },
        },
      },
    };
    expect(providerWindow(catalog, "opencode-go", models)).toBe("mixed");
  });

  test("reports null when no provider override is set", () => {
    expect(providerWindow(catalog, "opencode-go", {})).toBeNull();
  });
});

describe("formatFullStatus", () => {
  test("prints the full status block in owner order", () => {
    expect(
      formatFullStatus({
        session: null,
        model: 500000,
        provider: "mixed",
        global: 256000,
        effective: 256000,
        source: "global",
        native: 1000000,
      }),
    ).toEqual([
      "session unset",
      "model 500000",
      "provider mixed",
      "global 256000",
      "effective 256000 (global) of 1000000 native",
    ]);
  });
});

describe("formatScopeStatus", () => {
  test("prints one labeled line for a single-scope query", () => {
    expect(formatScopeStatus("session", null)).toBe("session unset");
    expect(formatScopeStatus("global", 256000)).toBe("global 256000");
    expect(formatScopeStatus("model", 500000)).toBe("model 500000");
    expect(formatScopeStatus("provider", { value: 200000, count: 3 })).toBe("provider 200000 (3 models)");
    expect(formatScopeStatus("provider", "mixed")).toBe("provider mixed");
  });
});

describe("effectiveWindow and the written-cap mirror", () => {
  const staleSettings = { contextWindowCap: 256000 };
  const base = { baseline: 1000000, session: null, models: null as Json | null };
  const models: Json = {
    providers: { "opencode-go": { modelOverrides: { "glm-5.1": { contextWindow: 900000 } } } },
  };

  afterEach(() => resetWrittenCap());

  test("pi is authoritative before any write", () => {
    resetWrittenCap();
    expect(effectiveWindow(active, { ...base, settings: staleSettings })).toEqual({
      window: 256000,
      source: "global",
    });
  });

  test("the written cap survives a later selection while pi still reports the old one", () => {
    resetWrittenCap();
    const paths = tempPaths({ settings: '{"contextWindowCap":256000}\n' });
    noteWrittenCap(applyToFiles(parseCommand("100000 global", active), paths, catalog));
    expect(effectiveWindow(active, { ...base, settings: staleSettings })).toEqual({
      window: 100000,
      source: "global",
    });
    expect(effectiveWindow(active, { ...base, settings: { contextWindowCap: 999 } }).window).toBe(100000);
  });

  test("clearing keeps the cap gone, and a reload restores pi's value", () => {
    resetWrittenCap();
    const paths = tempPaths({ settings: '{"contextWindowCap":256000}\n' });
    noteWrittenCap(applyToFiles(parseCommand("default global", active), paths, catalog));
    expect(effectiveWindow(active, { ...base, settings: staleSettings })).toEqual({
      window: 1000000,
      source: "native",
    });
    resetWrittenCap();
    expect(effectiveWindow(active, { ...base, settings: staleSettings })).toEqual({
      window: 256000,
      source: "global",
    });
  });

  test("a models.json write leaves the cap mirror alone", () => {
    resetWrittenCap();
    const paths = tempPaths({ models: "{}\n" });
    noteWrittenCap(applyToFiles(parseCommand("500000 model", active), paths, catalog));
    expect(effectiveWindow(active, { ...base, settings: staleSettings })).toEqual({
      window: 256000,
      source: "global",
    });
  });

  test("the models.json override wins over the cap", () => {
    expect(effectiveWindow(active, { baseline: 1000000, session: null, models, settings: staleSettings })).toEqual({
      window: 900000,
      source: "model",
    });
  });
});

describe("syncModelWindow", () => {
  afterEach(() => resetWrittenCap());

  test("mutates the active model window and nudges ui when the effective value changes", () => {
    const model = { provider: active.provider, id: active.id, contextWindow: 1000000 };
    const calls: Array<[string, string | undefined]> = [];
    const ui = { setStatus: (key: string, value: string | undefined) => calls.push([key, value]) };

    const result = syncModelWindow(model, 1000000, null, null, { contextWindowCap: 256000 }, ui);

    expect(result).toEqual({ changed: true, window: 256000, source: "global" });
    expect(model.contextWindow).toBe(256000);
    expect(calls).toEqual([["context-window", ""], ["context-window", undefined]]);
  });

  test("does not nudge ui when the effective window is unchanged", () => {
    const model = { provider: active.provider, id: active.id, contextWindow: 256000 };
    const calls: Array<[string, string | undefined]> = [];
    const ui = { setStatus: (key: string, value: string | undefined) => calls.push([key, value]) };

    const result = syncModelWindow(model, 1000000, null, null, { contextWindowCap: 256000 }, ui);

    expect(result).toEqual({ changed: false, window: 256000, source: "global" });
    expect(model.contextWindow).toBe(256000);
    expect(calls).toEqual([]);
  });

  test("session override takes precedence immediately", () => {
    const model = { provider: active.provider, id: active.id, contextWindow: 1000000 };
    const models: Json = {
      providers: { "opencode-go": { modelOverrides: { "glm-5.1": { contextWindow: 900000 } } } },
    };

    const result = syncModelWindow(model, 1000000, 300000, models, { contextWindowCap: 256000 });

    expect(result).toEqual({ changed: true, window: 300000, source: "session" });
    expect(model.contextWindow).toBe(300000);
  });

  test("global set and clear affect the active model through the written-cap mirror", () => {
    const model = { provider: active.provider, id: active.id, contextWindow: 1000000 };
    const staleSettings = { contextWindowCap: 256000 };
    const paths = tempPaths({ settings: '{"contextWindowCap":256000}\n' });

    noteWrittenCap(applyToFiles(parseCommand("100000 global", active), paths, catalog));
    const capped = syncModelWindow(model, 1000000, null, null, staleSettings);
    expect(capped).toEqual({ changed: true, window: 100000, source: "global" });
    expect(model.contextWindow).toBe(100000);

    noteWrittenCap(applyToFiles(parseCommand("default global", active), paths, catalog));
    const cleared = syncModelWindow(model, 1000000, null, null, staleSettings);
    expect(cleared).toEqual({ changed: true, window: 1000000, source: "native" });
    expect(model.contextWindow).toBe(1000000);
  });

  test("negative clear affects the active model the same way as default", () => {
    const model = { provider: active.provider, id: active.id, contextWindow: 256000 };
    const staleSettings = { contextWindowCap: 256000 };
    const paths = tempPaths({ settings: '{"contextWindowCap":256000}\n' });

    noteWrittenCap(applyToFiles(parseCommand("-1 global", active), paths, catalog));
    const cleared = syncModelWindow(model, 1000000, null, null, staleSettings);
    expect(cleared).toEqual({ changed: true, window: 1000000, source: "native" });
    expect(model.contextWindow).toBe(1000000);
  });

  test("model write affects the active model immediately and clearing restores the correct layer", () => {
    const model = { provider: active.provider, id: active.id, contextWindow: 1000000 };
    const paths = tempPaths({ models: "{}\n" });

    applyToFiles(parseCommand("500000 model", active), paths, catalog);
    const models = JSON.parse(readFileSync(paths.models, "utf8")) as Json;
    const explicit = syncModelWindow(model, 1000000, null, models, { contextWindowCap: 256000 });
    expect(explicit).toEqual({ changed: true, window: 500000, source: "model" });
    expect(model.contextWindow).toBe(500000);

    applyToFiles(parseCommand("default model", active), paths, catalog);
    const clearedModels = JSON.parse(readFileSync(paths.models, "utf8")) as Json;
    const cleared = syncModelWindow(model, 1000000, null, clearedModels, { contextWindowCap: 256000 });
    expect(cleared).toEqual({ changed: true, window: 256000, source: "global" });
    expect(model.contextWindow).toBe(256000);
  });

  test("provider write affects the active model immediately and clearing restores native when no other layer applies", () => {
    const model = { provider: active.provider, id: active.id, contextWindow: 1000000 };
    const paths = tempPaths({ models: "{}\n" });

    applyToFiles(parseCommand("200000 provider opencode-go", active), paths, catalog);
    const models = JSON.parse(readFileSync(paths.models, "utf8")) as Json;
    const explicit = syncModelWindow(model, 1000000, null, models, {});
    expect(explicit).toEqual({ changed: true, window: 200000, source: "model" });
    expect(model.contextWindow).toBe(200000);

    applyToFiles(parseCommand("-1 provider opencode-go", active), paths, catalog);
    const clearedModels = JSON.parse(readFileSync(paths.models, "utf8")) as Json;
    const cleared = syncModelWindow(model, 1000000, null, clearedModels, {});
    expect(cleared).toEqual({ changed: true, window: 1000000, source: "native" });
    expect(model.contextWindow).toBe(1000000);
  });
});

describe("applyToFiles", () => {
  test("global set writes a sorted cap with one trailing newline", () => {
    const paths = tempPaths({
      settings: '{"compact":true,"$schema":"https://example.invalid/settings.json"}\n',
    });
    const outcome = applyToFiles(parseCommand("256000 global", active), paths, catalog);
    expect(outcome.kind).toBe("written");
    expect(readFileSync(paths.settings, "utf8")).toBe(
      '{\n  "$schema": "https://example.invalid/settings.json",\n  "compact": true,\n  "contextWindowCap": 256000\n}\n',
    );
  });

  test("global clear removes only the cap", () => {
    const paths = tempPaths({
      settings: '{"$schema":"https://example.invalid/settings.json","contextWindowCap":256000,"defaultProvider":"opencode-go"}\n',
    });
    expect(applyToFiles(parseCommand("default global", active), paths, catalog).kind).toBe("written");
    expect(JSON.parse(readFileSync(paths.settings, "utf8"))).toEqual({
      $schema: "https://example.invalid/settings.json",
      defaultProvider: "opencode-go",
    });
  });

  test("model set creates the provider section for the explicit target", () => {
    const paths = tempPaths({ models: "{}\n" });
    expect(
      applyToFiles(parseCommand("500000 model anthropic/claude-sonnet-5", active), paths, catalog).kind,
    ).toBe("written");
    expect(JSON.parse(readFileSync(paths.models, "utf8"))).toEqual({
      providers: { anthropic: { modelOverrides: { "claude-sonnet-5": { contextWindow: 500000 } } } },
    });
  });

  test("provider set covers catalog ids, listed models, and existing overrides", () => {
    const paths = tempPaths({
      models: JSON.stringify({
        providers: {
          anthropic: {
            apiKey: "env:ANTHROPIC_API_KEY",
            models: [{ id: "claude-haiku-5" }],
            modelOverrides: { "retired-model": { contextWindow: 1 } },
          },
          other: { modelOverrides: { x: { contextWindow: 1 } } },
        },
      }),
    });
    expect(applyToFiles(parseCommand("200000 provider anthropic", active), paths, catalog).kind).toBe("written");
    expect(JSON.parse(readFileSync(paths.models, "utf8"))).toEqual({
      providers: {
        anthropic: {
          apiKey: "env:ANTHROPIC_API_KEY",
          models: [{ id: "claude-haiku-5" }],
          modelOverrides: {
            "claude-haiku-5": { contextWindow: 200000 },
            "claude-sonnet-5": { contextWindow: 200000 },
            "retired-model": { contextWindow: 200000 },
          },
        },
        other: { modelOverrides: { x: { contextWindow: 1 } } },
      },
    });
  });

  test("clear removes only what it emptied", () => {
    const paths = tempPaths({
      models: JSON.stringify({
        providers: {
          anthropic: {
            apiKey: "env:ANTHROPIC_API_KEY",
            modelOverrides: {
              "claude-sonnet-5": { contextWindow: 500000 },
              "claude-opus-4": { contextWindow: 900000, maxTokens: 64000 },
            },
          },
        },
      }),
    });
    expect(applyToFiles(parseCommand("default model anthropic/claude-sonnet-5", active), paths, catalog).kind).toBe(
      "written",
    );
    expect(JSON.parse(readFileSync(paths.models, "utf8"))).toEqual({
      providers: {
        anthropic: {
          apiKey: "env:ANTHROPIC_API_KEY",
          modelOverrides: { "claude-opus-4": { contextWindow: 900000, maxTokens: 64000 } },
        },
      },
    });
  });

  test("a missing file writes nothing", () => {
    const paths = tempPaths();
    for (const input of ["256000 global", "500000 model", "200000 provider"]) {
      const outcome = applyToFiles(parseCommand(input, active), paths, catalog);
      expect(outcome.kind).toBe("refused");
      expect(existsSync(paths.settings)).toBe(false);
      expect(existsSync(paths.models)).toBe(false);
    }
  });

  test("an unparsable file is left untouched", () => {
    const paths = tempPaths({ settings: "{not json", models: "{not json" });
    for (const input of ["256000 global", "500000 model"]) {
      expect(applyToFiles(parseCommand(input, active), paths, catalog).kind).toBe("refused");
    }
    expect(readFileSync(paths.settings, "utf8")).toBe("{not json");
    expect(readFileSync(paths.models, "utf8")).toBe("{not json");
  });

  test("a provider with no known models writes nothing", () => {
    const paths = tempPaths({ models: "{}\n" });
    const outcome = applyToFiles(parseCommand("200000 provider nobody", active), paths, catalog);
    expect(outcome.kind).toBe("refused");
    expect(readFileSync(paths.models, "utf8")).toBe("{}\n");
  });

  test("a session command touches no file", () => {
    const paths = tempPaths();
    expect(applyToFiles(parseCommand("200000", active), paths, catalog)).toEqual({ kind: "none" });
    expect(existsSync(paths.settings)).toBe(false);
    expect(existsSync(paths.models)).toBe(false);
  });

  test("writing through a symlink keeps the link and updates the target", () => {
    const paths = tempPaths();
    const target = join(dirname(paths.settings), "settings.real.json");
    writeFileSync(target, "{}\n", "utf8");
    symlinkSync(target, paths.settings);
    expect(applyToFiles(parseCommand("256000 global", active), paths, catalog).kind).toBe("written");
    expect(lstatSync(paths.settings).isSymbolicLink()).toBe(true);
    expect(readFileSync(target, "utf8")).toBe('{\n  "contextWindowCap": 256000\n}\n');
  });

  test("writing through a hardlink keeps both names on one inode", () => {
    const paths = tempPaths({ settings: "{}\n" });
    const sibling = join(dirname(paths.settings), "settings.sibling.json");
    linkSync(paths.settings, sibling);
    expect(statSync(paths.settings).nlink).toBe(2);
    expect(applyToFiles(parseCommand("256000 global", active), paths, catalog).kind).toBe("written");
    expect(readFileSync(sibling, "utf8")).toBe('{\n  "contextWindowCap": 256000\n}\n');
    expect(lstatSync(paths.settings).nlink).toBe(2);
    expect(statSync(paths.settings).ino).toBe(statSync(sibling).ino);
  });
});

const stubTheme: FooterTheme = { fg: (_color, text) => text, bold: (text) => text };

function recordingTheme(): { theme: FooterTheme; calls: Array<[string, string]> } {
  const calls: Array<[string, string]> = [];
  return {
    calls,
    theme: {
      fg: (color, text) => {
        calls.push([color, text]);
        return text;
      },
      bold: (text) => text,
    },
  };
}

// Every field is set so a case only spells out what it probes.
function footerSnapshot(overrides: Partial<FooterSnapshot> = {}): FooterSnapshot {
  return {
    cwd: "/home/user/project",
    home: "/home/user",
    branch: null,
    sessionName: null,
    modelId: "glm-5.1",
    provider: "opencode-go",
    providerCount: 1,
    reasoning: false,
    thinkingLevel: null,
    tokens: 35200,
    effectiveWindow: 100000,
    source: "native",
    usage: { input: 12000, output: 3000, cacheRead: 8000, cacheWrite: 0, cost: 0.123 },
    latestCacheHitRate: 40,
    subscription: false,
    statuses: [],
    ...overrides,
  };
}

function entryUsage(input: number, output: number, cacheRead: number, cacheWrite: number, cost: number) {
  return { input, output, cacheRead, cacheWrite, cost: { total: cost } };
}

// Costs are binary-exact so the summed total compares with toEqual.
function footerSource(): FooterSnapshotSource {
  return {
    model: { provider: "opencode-go", id: "glm-5.1", reasoning: true },
    thinkingLevel: "high",
    sessionManager: {
      getEntries: () => [
        { type: "message", message: { role: "assistant", usage: entryUsage(1000, 500, 500, 0, 0.5) } },
        { type: "message", message: { role: "toolResult", usage: entryUsage(100, 0, 0, 0, 0.25) } },
        { type: "usage", usage: entryUsage(200, 0, 0, 0, 0.125) },
        { type: "compaction", usage: entryUsage(50, 0, 0, 0, 0.125) },
      ],
      getCwd: () => "/home/user/project",
      getSessionName: () => "refactor",
    },
    modelRegistry: { isUsingOAuth: () => true },
    getContextUsage: () => ({ tokens: 35200 }),
    footerData: {
      getGitBranch: () => "main",
      getExtensionStatuses: () => new Map([["zeta", "last"], ["alpha", "first"]]),
      getAvailableProviderCount: () => 2,
    },
  };
}

describe("renderFooterLines", () => {
  test("the effective window sets the denominator while token totals stay fixed", () => {
    const narrow = renderFooterLines(footerSnapshot({ effectiveWindow: 100000, source: "session" }), 200, stubTheme);
    const wide = renderFooterLines(footerSnapshot({ effectiveWindow: 200000, source: "session" }), 200, stubTheme);
    expect(narrow[1]).toContain("35.2%/100k (session)");
    expect(wide[1]).toContain("17.6%/200k (session)");
    expect(narrow[1]).not.toBe(wide[1]);
  });

  test("unknown tokens render ?/<window>", () => {
    const lines = renderFooterLines(
      footerSnapshot({ tokens: null, effectiveWindow: 256000, source: "global" }),
      200,
      stubTheme,
    );
    expect(lines[1]).toContain("?/256k (global)");
  });

  test("the percent thresholds pick the warning and error colors", () => {
    const half = recordingTheme();
    renderFooterLines(footerSnapshot({ tokens: 50000 }), 200, half.theme);
    expect(half.calls.some(([color]) => color === "warning" || color === "error")).toBe(false);

    const seventyOne = recordingTheme();
    renderFooterLines(footerSnapshot({ tokens: 71000 }), 200, seventyOne.theme);
    expect(seventyOne.calls).toContainEqual(["warning", "71.0%/100k"]);

    const ninetyOne = recordingTheme();
    renderFooterLines(footerSnapshot({ tokens: 91000 }), 200, ninetyOne.theme);
    expect(ninetyOne.calls).toContainEqual(["error", "91.0%/100k"]);
  });

  test("the provider prefix appears only when several providers are available", () => {
    const single = renderFooterLines(footerSnapshot({ providerCount: 1 }), 200, stubTheme);
    expect(single[1]).toContain("glm-5.1");
    expect(single[1]).not.toContain("(opencode-go)");

    const several = renderFooterLines(footerSnapshot({ providerCount: 2 }), 200, stubTheme);
    expect(several[1]).toContain("(opencode-go) glm-5.1");
  });

  test("a narrow width truncates the model side to what the stats leave, then folds it away", () => {
    // The stats take 42 of the 46 cells, so the model side is cut to the two
    // cells left past the gap, and the provider prefix never survives: it is
    // dropped before truncation because it is what fails the fit test.
    const tight = renderFooterLines(footerSnapshot({ providerCount: 2 }), 46, stubTheme);
    expect(tight[1]).toBe("↑12k ↓3.0k R8.0k CH40.0% $0.123 35.2%/100k  gl");
    expect(tight[1]).not.toContain("(opencode-go)");

    // Below the stats' own width the budget for the model side is gone, so the
    // stats are truncated instead and the model segment drops out entirely.
    const narrower = renderFooterLines(footerSnapshot({ providerCount: 2 }), 40, stubTheme);
    expect(narrower[1]).toBe("↑12k ↓3.0k R8.0k CH40.0% $0.123 35.2%...");
    expect(narrower[1]).not.toContain("glm-5.1");
  });

  test("statuses render on a third line in the given order and only when present", () => {
    const withStatuses = renderFooterLines(
      footerSnapshot({ statuses: ["build ok", "tests\n3/3\tgreen"] }),
      200,
      stubTheme,
    );
    expect(withStatuses).toHaveLength(3);
    expect(withStatuses[2]).toBe("build ok tests 3/3 green");

    expect(renderFooterLines(footerSnapshot(), 200, stubTheme)).toHaveLength(2);
  });

  test("line 1 shortens the cwd under home and appends the branch and session name", () => {
    const lines = renderFooterLines(footerSnapshot({ branch: "main", sessionName: "refactor" }), 200, stubTheme);
    expect(lines[0]).toBe("~/project (main) • refactor");
  });

  test("a model-less snapshot renders ?/0 with no source label", () => {
    const lines = renderFooterLines(
      footerSnapshot({ modelId: null, provider: null, reasoning: false, tokens: null, effectiveWindow: 0 }),
      200,
      stubTheme,
    );
    expect(lines[1]).toContain("?/0");
    expect(lines[1]).toContain("no-model");
    expect(lines[1]).not.toContain("(native)");
  });
});

describe("footer formatting helpers", () => {
  test("formatTokens matches the native buckets", () => {
    expect([999, 1500, 35000, 1500000, 35000000].map(formatTokens)).toEqual(["999", "1.5k", "35k", "1.5M", "35M"]);
  });

  test("footerCwd shortens only a cwd inside home", () => {
    expect(footerCwd("/home/user/project", "/home/user")).toBe("~/project");
    expect(footerCwd("/home/user", "/home/user")).toBe("~");
    expect(footerCwd("/tmp", "/home/user")).toBe("/tmp");
    expect(footerCwd("/home/user2", "/home/user")).toBe("/home/user2");
    expect(footerCwd("/home/user/project", "")).toBe("/home/user/project");
  });

  test("visibleWidth ignores ANSI sequences and truncation closes the style it cut", () => {
    expect(footerFormatting.visibleWidth("\x1b[2mabc\x1b[0m")).toBe(3);
    expect(footerFormatting.truncateToWidth("\x1b[2mabcdef\x1b[0m", 4, "...")).toBe("\x1b[2ma\x1b[0m...");
  });
});

describe("buildFooterSnapshot", () => {
  test("sums usage, keeps the latest cache hit rate, and orders statuses by key", () => {
    const snapshot = buildFooterSnapshot(footerSource(), { window: 100000, source: "session" });
    expect(snapshot.usage).toEqual({ input: 1350, output: 500, cacheRead: 500, cacheWrite: 0, cost: 1 });
    expect(snapshot.latestCacheHitRate).toBeCloseTo(33.33, 2);
    expect(snapshot.statuses).toEqual(["first", "last"]);
    expect(snapshot.tokens).toBe(35200);
    expect(snapshot.effectiveWindow).toBe(100000);
    expect(snapshot.source).toBe("session");
    expect(snapshot.modelId).toBe("glm-5.1");
    expect(snapshot.provider).toBe("opencode-go");
    expect(snapshot.providerCount).toBe(2);
    expect(snapshot.reasoning).toBe(true);
    expect(snapshot.thinkingLevel).toBe("high");
    expect(snapshot.subscription).toBe(true);
    expect(snapshot.branch).toBe("main");
    expect(snapshot.sessionName).toBe("refactor");
    expect(snapshot.cwd).toBe("/home/user/project");
  });

  test("a missing model and unknown context usage render as no-model and ?/0", () => {
    const snapshot = buildFooterSnapshot(
      { ...footerSource(), model: undefined, getContextUsage: () => undefined },
      { window: 0, source: "native" },
    );
    expect(snapshot.modelId).toBeNull();
    expect(snapshot.provider).toBeNull();
    expect(snapshot.reasoning).toBe(false);
    expect(snapshot.thinkingLevel).toBe("high");
    expect(snapshot.tokens).toBeNull();
    expect(snapshot.subscription).toBe(false);
    expect(renderFooterLines(snapshot, 80, stubTheme)[1]).toContain("no-model");
    expect(renderFooterLines(snapshot, 80, stubTheme)[1]).toContain("?/0");
  });
});

// --- Fake extension host -----------------------------------------------------
// The default export is the extension's only entry point, so the wiring cases
// below drive it through a fake host instead of reaching into module state. The
// fake carries only the members this extension touches, which no pi runtime type
// describes, so it is cast at the ExtensionAPI and ExtensionContext seams.

interface FakeModel {
  provider: string;
  id: string;
  contextWindow: number;
  reasoning: boolean;
}

interface FakeTui {
  requestRender(): void;
}

interface FakeFooterData {
  branchChangeCallbacks: Array<() => void>;
  subscribed: boolean;
  getGitBranch(): string | null;
  getExtensionStatuses(): ReadonlyMap<string, string>;
  getAvailableProviderCount(): number;
  onBranchChange(callback: () => void): () => void;
}

interface FakeFooter {
  render(width: number): string[];
  dispose?(): void;
}

type FooterFactory = (tui: FakeTui, theme: FooterTheme, footerData: FakeFooterData) => FakeFooter;

interface FakeUi {
  footerFactories: FooterFactory[];
  statusCalls: Array<[key: string, value: string | undefined]>;
  notifications: Array<[message: string, level: string]>;
  setFooter(factory: FooterFactory): void;
  setStatus(key: string, value: string | undefined): void;
  notify(message: string, level: string): void;
}

interface FakeContext {
  mode: string;
  ui: FakeUi;
  model: FakeModel | undefined;
  thinkingLevel: string;
  getContextUsage(): { tokens: number | null; contextWindow: number; percent: number | null } | undefined;
  sessionManager: { getEntries(): unknown[]; getCwd(): string; getSessionName(): string | null };
  modelRegistry: { isUsingOAuth(model: FakeModel): boolean; getAll(): Array<{ provider: string; id: string }> };
  cwd: string;
  hasUI: boolean;
  scopedModels: unknown[];
}

interface FakePi {
  on(event: string, handler: (event: unknown, ctx: unknown) => unknown): void;
  registerCommand(name: string, command: { handler: (args: string, ctx: unknown) => Promise<void> }): void;
  getSettings(): Record<string, unknown>;
  emit(event: string, payload: unknown, ctx: unknown): unknown;
  command(name: string, args: string, ctx: unknown): Promise<void>;
}

// Test-only ids: the extension reads models.json under the process home, which
// bun fixes at process start, so an id no real file carries keeps that read from
// finding an override.
const TEST_PROVIDER = "test-provider";
const TEST_MODEL = "test-model";
const TEST_TOKENS = 35200;

function fakeModel(overrides: Partial<FakeModel> = {}): FakeModel {
  return { provider: TEST_PROVIDER, id: TEST_MODEL, contextWindow: 100000, reasoning: false, ...overrides };
}

function fakeUi(): FakeUi {
  const ui: FakeUi = {
    footerFactories: [],
    statusCalls: [],
    notifications: [],
    setFooter: (factory) => ui.footerFactories.push(factory),
    setStatus: (key, value) => ui.statusCalls.push([key, value]),
    notify: (message, level) => ui.notifications.push([message, level]),
  };
  return ui;
}

function fakeFooterData(): FakeFooterData {
  const footerData: FakeFooterData = {
    branchChangeCallbacks: [],
    subscribed: false,
    getGitBranch: () => null,
    getExtensionStatuses: () => new Map<string, string>(),
    getAvailableProviderCount: () => 1,
    onBranchChange: (callback) => {
      footerData.branchChangeCallbacks.push(callback);
      footerData.subscribed = true;
      return () => {
        footerData.subscribed = false;
      };
    },
  };
  return footerData;
}

function fakeContext(ui: FakeUi, overrides: Partial<Omit<FakeContext, "ui">> = {}): FakeContext {
  return {
    mode: "tui",
    ui,
    model: fakeModel(),
    thinkingLevel: "high",
    getContextUsage: () => ({ tokens: TEST_TOKENS, contextWindow: 100000, percent: (TEST_TOKENS / 100000) * 100 }),
    sessionManager: { getEntries: () => [], getCwd: () => "/home/user/project", getSessionName: () => null },
    modelRegistry: { isUsingOAuth: () => false, getAll: () => [] },
    cwd: "/home/user/project",
    hasUI: true,
    scopedModels: [],
    ...overrides,
  };
}

function fakePi(settings: Record<string, unknown> = {}): FakePi {
  const handlers = new Map<string, Array<(event: unknown, ctx: unknown) => unknown>>();
  const commands = new Map<string, { handler: (args: string, ctx: unknown) => Promise<void> }>();
  const pi: FakePi = {
    on: (event, handler) => {
      handlers.set(event, [...(handlers.get(event) ?? []), handler]);
    },
    registerCommand: (name, command) => {
      commands.set(name, command);
    },
    getSettings: () => settings,
    emit: (event, payload, ctx) => {
      let result: unknown;
      for (const handler of handlers.get(event) ?? []) result = handler(payload, ctx);
      return result;
    },
    command: async (name, args, ctx) => {
      const command = commands.get(name);
      if (command === undefined) throw new Error(`the extension registered no command named ${name}`);
      await command.handler(args, ctx);
    },
  };
  return pi;
}

function startExtension(settings: Record<string, unknown> = {}): FakePi {
  const pi = fakePi(settings);
  contextCap(pi as unknown as ExtensionAPI);
  return pi;
}

function emitEvent(pi: FakePi, event: string, payload: unknown, ctx: FakeContext): void {
  pi.emit(event, payload, ctx as unknown as ExtensionContext);
}

// Mounting the factory is what pi's interactive mode does on the next frame.
function mountFooter(
  ui: FakeUi,
  footerData: FakeFooterData,
  index = ui.footerFactories.length - 1,
): FakeFooter {
  const factory = ui.footerFactories[index];
  if (factory === undefined) throw new Error(`no footer factory installed at index ${index}`);
  return factory({ requestRender: () => {} }, stubTheme, footerData);
}

describe("footer wiring through a fake extension host", () => {
  let pi: FakePi;

  beforeEach(() => {
    resetWrittenCap();
    pi = startExtension({ contextWindowCap: 256000 });
  });

  test("a tui session_start installs exactly one footer that renders at least two lines", () => {
    const ui = fakeUi();
    emitEvent(pi, "session_start", { reason: "startup" }, fakeContext(ui));

    expect(ui.footerFactories).toHaveLength(1);
    const lines = mountFooter(ui, fakeFooterData()).render(80);
    expect(lines.length).toBeGreaterThanOrEqual(2);
    expect(lines[1]).toContain(`${((TEST_TOKENS / 100000) * 100).toFixed(1)}%/100k`);
  });

  test("a print or json session_start installs no footer", () => {
    for (const mode of ["print", "json"]) {
      const ui = fakeUi();
      emitEvent(pi, "session_start", { reason: "startup" }, fakeContext(ui, { mode }));

      expect(ui.footerFactories).toHaveLength(0);
      expect(ui.statusCalls).toHaveLength(0);
    }
  });

  test("a reload installs a fresh footer that serves the reloaded context", () => {
    const ui = fakeUi();
    emitEvent(
      pi,
      "session_start",
      { reason: "startup" },
      fakeContext(ui, { model: fakeModel({ id: "first-model" }) }),
    );
    emitEvent(
      pi,
      "session_start",
      { reason: "reload" },
      fakeContext(ui, { model: fakeModel({ id: "second-model" }) }),
    );

    expect(ui.footerFactories).toHaveLength(2);
    const footerData = fakeFooterData();
    expect(mountFooter(ui, footerData, 0).render(80)[1]).toContain("first-model");
    expect(mountFooter(ui, footerData, 1).render(80)[1]).toContain("second-model");
  });

  test("the component reads the effective window per render, not per install", () => {
    const ui = fakeUi();
    const context = fakeContext(ui, { model: fakeModel({ contextWindow: 100000 }) });
    emitEvent(pi, "session_start", { reason: "startup" }, context);
    const component = mountFooter(ui, fakeFooterData());

    const before = component.render(80);
    expect(before[1]).toContain("/100k");

    // getContextUsage().tokens is the fake's constant, so only the window moved:
    // the 256000 cap replaces the 1,000,000 native window on this selection.
    emitEvent(pi, "model_select", { model: fakeModel({ contextWindow: 1000000 }) }, context);

    const after = component.render(80);
    expect(after[1]).toContain("/256k (global)");
    expect(after[1]).not.toBe(before[1]);
  });

  test("a model_select nudges the status so the footer repaints", () => {
    const ui = fakeUi();
    const context = fakeContext(ui);
    emitEvent(pi, "session_start", { reason: "startup" }, context);
    ui.statusCalls.length = 0;

    emitEvent(pi, "model_select", { model: fakeModel({ contextWindow: 1000000 }) }, context);

    expect(ui.statusCalls).toEqual([
      ["context-window", ""],
      ["context-window", undefined],
    ]);
  });

  test("dispose unsubscribes the branch-change listener", () => {
    const ui = fakeUi();
    emitEvent(pi, "session_start", { reason: "startup" }, fakeContext(ui));
    const footerData = fakeFooterData();
    const component = mountFooter(ui, footerData);

    expect(footerData.branchChangeCallbacks).toHaveLength(1);
    expect(footerData.subscribed).toBe(true);

    component.dispose?.();

    expect(footerData.subscribed).toBe(false);
  });

  test("a model-less tui session_start still installs the footer and renders ?/0", () => {
    const ui = fakeUi();
    emitEvent(
      pi,
      "session_start",
      { reason: "startup" },
      fakeContext(ui, { model: undefined, getContextUsage: () => undefined }),
    );

    expect(ui.footerFactories).toHaveLength(1);
    const lines = mountFooter(ui, fakeFooterData()).render(80);
    expect(lines[1]).toContain("?/0");
    expect(lines[1]).not.toContain("(native)");
  });
});
