// Cases for the context-window extension: pure parsing and precedence, the
// deterministic serializer, and file round-trips against a temp directory so the
// session command's writes are exercised without touching ~/.pi. The re-selection
// cases register the extension with a fake pi, so their only real filesystem
// contact is the read-only models.json lookup applyCap makes under ~/.pi/agent.

import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { existsSync, lstatSync, linkSync, mkdtempSync, readFileSync, statSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import contextCap, {
  applyToFiles,
  effectiveWindow,
  formatFullStatus,
  formatScopeStatus,
  noteWrittenCap,
  parseCommand,
  providerWindow,
  readCap,
  refreshActiveModel,
  resetWrittenCap,
  resolveWindow,
  restoreRoutedWindows,
  serialize,
  setGlobalCap,
  setModelWindow,
  startWatchdog,
  stopWatchdog,
  syncModelWindow,
  syncRoutedWindow,
  WATCHDOG_INTERVAL_MS,
  watchdogTick,
  type ActiveModel,
  type CapHost,
  type CapUi,
  type FilePaths,
  type Json,
  type ModelCatalog,
  type ModelSelector,
  type RoutedSource,
  type RuntimeModel,
  type WatchdogSource,
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

describe("syncRoutedWindow", () => {
  afterEach(() => restoreRoutedWindows());

  // A routed selection's usage reports the physical model window, which changes
  // as the sync writes it, so each case supplies what pi would report at that
  // moment instead of a value fixed at construction.
  function routedSource(
    models: readonly RuntimeModel[],
    entries: () => readonly unknown[],
    usage: () => { contextWindow: number } | undefined,
  ): RoutedSource {
    return {
      sessionManager: { getEntries: entries },
      modelRegistry: {
        find: (provider, modelId) => models.find((model) => model.provider === provider && model.id === modelId),
      },
      getContextUsage: usage,
    };
  }

  function assistantEntry(message: { provider: string; model: string; responseModel?: string }): unknown {
    return { type: "message", message: { role: "assistant", ...message } };
  }

  test("writes the effective window onto the model the last assistant entry names", () => {
    const physical: RuntimeModel = { provider: "opencode-go", id: "glm-5.1", contextWindow: 1000000 };
    const earlier: RuntimeModel = { provider: "anthropic", id: "claude-sonnet-5", contextWindow: 200000 };
    const entries = [
      { type: "message", message: { role: "user", content: "hi" } },
      assistantEntry({ provider: "anthropic", model: "claude-sonnet-5" }),
      // responseModel is the id the provider actually answered with.
      assistantEntry({ provider: "opencode-go", model: "glm-5.1-preview", responseModel: "glm-5.1" }),
    ];
    const source = routedSource([physical, earlier], () => entries, () => ({ contextWindow: 1000000 }));

    const target = syncRoutedWindow(source, 256000);

    expect(target).toBe(physical);
    expect(physical.contextWindow).toBe(256000);
    expect(earlier.contextWindow).toBe(200000);
  });

  test("a second sync updates the recorded model without recording a new original", () => {
    const physical: RuntimeModel = { provider: "opencode-go", id: "glm-5.1", contextWindow: 1000000 };
    const entries = [assistantEntry({ provider: "opencode-go", model: "glm-5.1" })];
    let reported = 1000000;
    const source = routedSource([physical], () => entries, () => ({ contextWindow: reported }));

    expect(syncRoutedWindow(source, 256000)).toBe(physical);
    reported = 256000;
    expect(syncRoutedWindow(source, 200000)).toBe(physical);
    expect(physical.contextWindow).toBe(200000);

    // The first original, not the intermediate 256000, is what a restore returns.
    restoreRoutedWindows();
    expect(physical.contextWindow).toBe(1000000);
  });

  test("a different routed target restores the previous model and mutates the new one", () => {
    const first: RuntimeModel = { provider: "opencode-go", id: "glm-5.1", contextWindow: 1000000 };
    const second: RuntimeModel = { provider: "anthropic", id: "claude-sonnet-5", contextWindow: 200000 };
    let entries: unknown[] = [assistantEntry({ provider: "opencode-go", model: "glm-5.1" })];
    let reported = 1000000;
    const source = routedSource([first, second], () => entries, () => ({ contextWindow: reported }));
    expect(syncRoutedWindow(source, 256000)).toBe(first);

    entries = [assistantEntry({ provider: "anthropic", model: "claude-sonnet-5" })];
    reported = 200000;

    expect(syncRoutedWindow(source, 300000)).toBe(second);
    expect(first.contextWindow).toBe(1000000);
    expect(second.contextWindow).toBe(300000);
  });

  test("restoreRoutedWindows puts the recorded original back and a second call does nothing", () => {
    const physical: RuntimeModel = { provider: "opencode-go", id: "glm-5.1", contextWindow: 1000000 };
    const entries = [assistantEntry({ provider: "opencode-go", model: "glm-5.1" })];
    const source = routedSource([physical], () => entries, () => ({ contextWindow: 1000000 }));
    syncRoutedWindow(source, 256000);

    restoreRoutedWindows();
    expect(physical.contextWindow).toBe(1000000);
    restoreRoutedWindows();
    expect(physical.contextWindow).toBe(1000000);
  });

  test("a source that already reports the effective window mutates nothing", () => {
    const physical: RuntimeModel = { provider: "opencode-go", id: "glm-5.1", contextWindow: 256000 };
    const entries = [assistantEntry({ provider: "opencode-go", model: "glm-5.1" })];
    const agreeing = routedSource([physical], () => entries, () => ({ contextWindow: 256000 }));

    expect(syncRoutedWindow(agreeing, 256000)).toBeNull();
    expect(physical.contextWindow).toBe(256000);

    const unknown = routedSource([physical], () => entries, () => undefined);
    expect(syncRoutedWindow(unknown, 100000)).toBeNull();
    expect(physical.contextWindow).toBe(256000);
  });
});

// applyCap is a closure inside the extension factory, so the re-selection cases
// register the real extension with a fake pi and drive the handlers it registered.
// The fake supplies the two calls applyCap makes, the registry catalog the
// command handler reports through, and the settings getSettings returns; the
// extension still reads ~/.pi/agent/models.json itself, read-only.
type HandlerContext = {
  model?: RuntimeModel;
  ui: CapUi;
} & RoutedSource;
type ModelSelectHandler = (event: { model: RuntimeModel }, ctx: HandlerContext) => Promise<void> | void;
type SessionStartHandler = (event: { reason: string }, ctx: HandlerContext) => Promise<void> | void;
type SessionShutdownHandler = () => Promise<void> | void;
// The command handler also builds its status block from the registry catalog.
type CommandContext = Omit<HandlerContext, "modelRegistry"> & {
  modelRegistry: RoutedSource["modelRegistry"] & ModelCatalog;
};
type CommandHandler = (args: string, ctx: CommandContext) => Promise<void> | void;

const silentUi: CapUi = { setStatus: () => {}, notify: () => {} };

// Every handler hands ctx to applyCap, which reads the routed window from it;
// these cases are not routed, so the source reports no context usage at all.
const unrouted = {
  sessionManager: { getEntries: () => [] as readonly unknown[] },
  modelRegistry: { find: () => undefined as RuntimeModel | undefined },
  getContextUsage: () => undefined,
};

type RegisteredHandlers = {
  model_select: ModelSelectHandler;
  session_start: SessionStartHandler;
  session_shutdown: SessionShutdownHandler;
  command: CommandHandler;
};

function loadContextCap(settings: unknown, setModel: ModelSelector["setModel"]): RegisteredHandlers {
  const handlers: Partial<RegisteredHandlers> = {};
  const fakePi = {
    on: (name: string, handler: unknown) => {
      if (name === "model_select") handlers.model_select = handler as ModelSelectHandler;
      if (name === "session_start") handlers.session_start = handler as SessionStartHandler;
      if (name === "session_shutdown") handlers.session_shutdown = handler as SessionShutdownHandler;
      return () => {};
    },
    registerCommand: (name: string, options: { handler: CommandHandler }) => {
      if (name === "context-window") handlers.command = options.handler;
    },
    getSettings: () => settings,
    setModel,
  };
  contextCap(fakePi as unknown as Parameters<typeof contextCap>[0]);
  const { model_select: onModelSelect, session_start: onSessionStart, session_shutdown: onSessionShutdown, command } =
    handlers;
  // A missing handler would make every case below pass vacuously.
  if (!onModelSelect || !onSessionStart || !onSessionShutdown || !command) {
    throw new Error("context-cap registered no handlers");
  }
  return { model_select: onModelSelect, session_start: onSessionStart, session_shutdown: onSessionShutdown, command };
}

describe("refreshActiveModel", () => {
  test("re-selects a clone with the same provider and id and the requested window", async () => {
    const selected: RuntimeModel[] = [];
    const pi: ModelSelector = {
      setModel: async (model) => {
        selected.push(model);
        return true;
      },
    };
    const model: RuntimeModel = { provider: "opencode-go", id: "glm-5.1", contextWindow: 1000000 };

    await expect(refreshActiveModel(pi, model, 256000, 1000000)).resolves.toBe(true);

    expect(selected).toHaveLength(1);
    const clone = selected[0]!;
    expect(clone).not.toBe(model);
    expect(clone.provider).toBe(model.provider);
    expect(clone.id).toBe(model.id);
    expect(clone.contextWindow).toBe(256000);
    expect(model.contextWindow).toBe(1000000);
  });
});

describe("re-selecting the model", () => {
  afterEach(() => {
    restoreRoutedWindows();
    resetWrittenCap();
  });

  test("the re-keyed native baseline restores the native window when the cap is cleared", async () => {
    const settings: { contextWindowCap?: number } = { contextWindowCap: 256000 };
    const selected: RuntimeModel[] = [];
    const handlers = loadContextCap(settings, async (model) => {
      selected.push(model);
      return true;
    });
    await handlers.session_start({ reason: "start" }, { ui: silentUi, ...unrouted });
    const model: RuntimeModel = { provider: "context-cap-test", id: "rekey", contextWindow: 1000000 };

    await handlers.model_select({ model }, { ui: silentUi, ...unrouted });
    expect(selected).toHaveLength(1);
    const clone = selected[0]!;
    expect(clone.contextWindow).toBe(256000);

    // The cap is gone, so the next window must come from the native baseline that
    // refreshActiveModel re-keyed onto the clone, not from the clone's capped value.
    delete settings.contextWindowCap;
    await handlers.model_select({ model: clone }, { ui: silentUi, ...unrouted });

    expect(clone.contextWindow).toBe(1000000);
    expect(selected).toHaveLength(2);
    expect(selected[1]!.contextWindow).toBe(1000000);
  });

  test("a capped routed physical model selected directly keeps its native baseline", async () => {
    const settings: { contextWindowCap?: number } = { contextWindowCap: 256000 };
    const selected: RuntimeModel[] = [];
    const handlers = loadContextCap(settings, async (model) => {
      selected.push(model);
      return true;
    });
    await handlers.session_start({ reason: "start" }, { ui: silentUi, ...unrouted });

    // A routed selection shows the physical model's 1000000 window as the capped
    // 256000, which leaves the physical registry object carrying 256000.
    const physical: RuntimeModel = { provider: "context-cap-test", id: "routed-then-selected", contextWindow: 1000000 };
    const routed = {
      ui: silentUi,
      sessionManager: {
        getEntries: () => [
          { type: "message", message: { role: "assistant", provider: physical.provider, model: physical.id } },
        ],
      },
      modelRegistry: { find: () => physical },
      getContextUsage: () => ({ contextWindow: physical.contextWindow }),
    };
    const virtual: RuntimeModel = { provider: "pi-route", id: "virtual", contextWindow: 1000000 };
    await handlers.model_select({ model: virtual }, routed);
    expect(physical.contextWindow).toBe(256000);

    // With the cap still set, selecting that same physical object must read the
    // restored native window as the baseline, not the capped window the route left.
    await handlers.model_select({ model: physical }, routed);
    expect(physical.contextWindow).toBe(256000);

    // A later clear then has to restore the true native window.
    delete settings.contextWindowCap;
    await handlers.model_select({ model: selected[selected.length - 1]! }, routed);
    expect(selected[selected.length - 1]!.contextWindow).toBe(1000000);
  });

  test("an effective change re-selects once and an identical selection does not re-select again", async () => {
    const selected: RuntimeModel[] = [];
    const handlers = loadContextCap({ contextWindowCap: 256000 }, async (model) => {
      selected.push(model);
      return true;
    });
    await handlers.session_start({ reason: "start" }, { ui: silentUi, ...unrouted });
    const model: RuntimeModel = { provider: "context-cap-test", id: "once", contextWindow: 1000000 };

    await handlers.model_select({ model }, { ui: silentUi, ...unrouted });
    expect(selected).toHaveLength(1);
    expect(model.contextWindow).toBe(256000);

    // pi holds the clone now, so selecting the same provider and id again must not
    // append another model_change entry.
    await handlers.model_select({ model: selected[0]! }, { ui: silentUi, ...unrouted });
    expect(selected).toHaveLength(1);
  });

  test("a refused re-selection keeps the mutation, repaints, and warns once per session", async () => {
    const statusCalls: Array<[string, string | undefined]> = [];
    const notifications: Array<[string, string | undefined]> = [];
    const ui: CapUi = {
      setStatus: (key, value) => statusCalls.push([key, value]),
      notify: (message, type) => notifications.push([message, type]),
    };
    const settings: { contextWindowCap?: number } = { contextWindowCap: 256000 };
    let attempts = 0;
    const handlers = loadContextCap(settings, async () => {
      attempts += 1;
      return false;
    });
    await handlers.session_start({ reason: "start" }, { ui, ...unrouted });
    const model: RuntimeModel = { provider: "context-cap-test", id: "no-auth", contextWindow: 1000000 };

    await handlers.model_select({ model }, { ui, ...unrouted });
    expect(attempts).toBe(1);
    expect(model.contextWindow).toBe(256000);
    expect(statusCalls).toEqual([["context-window", ""], ["context-window", undefined]]);
    expect(notifications).toHaveLength(1);
    expect(notifications[0]![1]).toBe("warning");
    expect(notifications[0]![0]).toContain("context-cap-test/no-auth");
    expect(notifications[0]![0]).toContain("pi-powerline-footer");

    settings.contextWindowCap = 100000;
    await handlers.model_select({ model }, { ui, ...unrouted });
    expect(attempts).toBe(2);
    expect(model.contextWindow).toBe(100000);
    expect(notifications).toHaveLength(1);
  });

  test("a re-selection whose setModel re-emits model_select does not re-enter applyCap", async () => {
    const selected: RuntimeModel[] = [];
    const physical: RuntimeModel = { provider: "context-cap-test", id: "re-emit-physical", contextWindow: 1000000 };
    // applyCap reads the routed source once per run, so the count is what shows
    // whether the re-emitted handler re-entered it. The setModel count alone
    // cannot: a second applyCap reads the window the first one already applied,
    // so it returns before re-selecting whether or not the guard is there.
    let applyCapRuns = 0;
    const routed: HandlerContext = {
      ui: silentUi,
      sessionManager: {
        getEntries: () => {
          applyCapRuns += 1;
          return [
            { type: "message", message: { role: "assistant", provider: physical.provider, model: physical.id } },
          ];
        },
      },
      modelRegistry: { find: () => physical },
      getContextUsage: () => ({ contextWindow: physical.contextWindow }),
    };
    const handlers = loadContextCap({ contextWindowCap: 256000 }, async (model) => {
      selected.push(model);
      // A pi that does not suppress the re-selection's own model_select, so the
      // refreshing guard in the handler is what keeps applyCap from re-entering.
      await handlers.model_select({ model }, routed);
      return true;
    });
    await handlers.session_start({ reason: "start" }, { ui: silentUi, ...unrouted });
    const model: RuntimeModel = { provider: "pi-route", id: "re-emit", contextWindow: 1000000 };

    await handlers.model_select({ model }, routed);

    expect(selected).toHaveLength(1);
    expect(selected[0]!.contextWindow).toBe(256000);
    expect(applyCapRuns).toBe(1);
  });
});

// A routed selection displays the registry's physical model, which applyCap writes
// before it re-selects. These cases cap at session scope through the command
// handler so no case writes ~/.pi/agent/settings.json, and the session clear in the
// last case is then the one layer it can take away.
describe("routed selections through applyCap", () => {
  afterEach(() => {
    restoreRoutedWindows();
    resetWrittenCap();
  });

  // A session-capped routed selection: the virtual model is selected while the
  // assistant entry and the usage report both name the physical one. The session
  // override lives in the extension module, so each case sets it here.
  async function routedSessionCap() {
    const physical: RuntimeModel = { provider: "context-cap-test", id: "routed-physical", contextWindow: 1000000 };
    const virtual: RuntimeModel = { provider: "pi-route", id: "routed-virtual", contextWindow: 1000000 };
    const selected: RuntimeModel[] = [];
    // What the fake setModel saw at the moment it ran.
    const atSelect: Array<{ physicalWindow: number; cloneWindow: number }> = [];
    const handlers = loadContextCap({}, async (clone) => {
      selected.push(clone);
      atSelect.push({ physicalWindow: physical.contextWindow, cloneWindow: clone.contextWindow });
      return true;
    });
    const routed: HandlerContext = {
      ui: silentUi,
      sessionManager: {
        getEntries: () => [
          { type: "message", message: { role: "assistant", provider: physical.provider, model: physical.id } },
        ],
      },
      modelRegistry: {
        find: (provider, modelId) => (provider === physical.provider && modelId === physical.id ? physical : undefined),
      },
      getContextUsage: () => ({ contextWindow: physical.contextWindow }),
    };
    await handlers.session_start({ reason: "start" }, { ui: silentUi, ...unrouted });
    // The scratch model already sits at the cap, so this command sets the session
    // override without re-selecting anything and atSelect stays the routed case's.
    const scratch: RuntimeModel = { provider: "context-cap-test", id: "scratch", contextWindow: 256000 };
    await handlers.command("256000 session", {
      ui: silentUi,
      model: scratch,
      ...unrouted,
      modelRegistry: { find: () => undefined, getAll: () => [] },
    });
    await handlers.model_select({ model: virtual }, routed);
    return { handlers, physical, selected, atSelect, routed };
  }

  test("a routed selection applies the effective window to the physical model before re-selecting", async () => {
    const { physical, selected, atSelect } = await routedSessionCap();

    expect(atSelect).toEqual([{ physicalWindow: 256000, cloneWindow: 256000 }]);
    expect(physical.contextWindow).toBe(256000);
    expect(selected).toHaveLength(1);
    expect(selected[0]!.contextWindow).toBe(256000);
  });

  test("session shutdown restores the routed physical window", async () => {
    const { handlers, physical } = await routedSessionCap();
    expect(physical.contextWindow).toBe(256000);

    await handlers.session_shutdown();

    expect(physical.contextWindow).toBe(1000000);
  });

  test("a session-scope clear through the command handler restores the routed physical window", async () => {
    const { handlers, physical, selected, routed } = await routedSessionCap();
    expect(physical.contextWindow).toBe(256000);

    // pi holds the re-selected clone, and that clone is the model the command
    // handler reports as active.
    await handlers.command("default", {
      ...routed,
      model: selected[selected.length - 1]!,
      modelRegistry: { find: routed.modelRegistry.find, getAll: () => [] },
    });

    expect(physical.contextWindow).toBe(1000000);
  });
});

// pi can put a pristine registry model back on agent.state.model without firing
// model_select (_refreshCurrentModelFromRegistry, agent-session.js:2607), which
// discards the clone this file selected. The watchdog ticks until the window pi
// holds matches the one this file applied. These cases drive watchdogTick
// directly except the stop and wiring ones, which let a real interval run and
// stop it in afterEach.
describe("watchdog", () => {
  beforeEach(() => stopWatchdog());

  afterEach(() => {
    stopWatchdog();
    restoreRoutedWindows();
    resetWrittenCap();
  });

  function capHost(settings: unknown, setModel: ModelSelector["setModel"]): CapHost {
    return { setModel, getSettings: () => settings };
  }

  function pristineModel(id: string): RuntimeModel {
    return { provider: "context-cap-test", id, contextWindow: 1000000 };
  }

  test("a tick whose model window differs from the last applied window re-applies", async () => {
    const settings = { contextWindowCap: 256000 };
    const selected: RuntimeModel[] = [];
    const setModel = async (model: RuntimeModel) => {
      selected.push(model);
      return true;
    };
    const handlers = loadContextCap(settings, setModel);
    const host = capHost(settings, setModel);
    const model = pristineModel("watchdog-replaces");

    await handlers.model_select({ model }, { ui: silentUi, ...unrouted });
    expect(selected).toHaveLength(1);
    expect(selected[0]!.contextWindow).toBe(256000);

    // A provider registration inside pi swaps the clone for a pristine registry
    // model, so the window pi holds no longer matches the applied one.
    const replacement = pristineModel("watchdog-replaces");
    await watchdogTick(host, { model: replacement, ui: silentUi, ...unrouted });

    expect(selected).toHaveLength(2);
    expect(selected[1]!.contextWindow).toBe(256000);
    expect(replacement.contextWindow).toBe(256000);
  });

  test("a tick whose window already matches does nothing", async () => {
    const settings = { contextWindowCap: 256000 };
    const selected: RuntimeModel[] = [];
    const setModel = async (model: RuntimeModel) => {
      selected.push(model);
      return true;
    };
    const handlers = loadContextCap(settings, setModel);
    const host = capHost(settings, setModel);

    await handlers.model_select({ model: pristineModel("watchdog-matches") }, { ui: silentUi, ...unrouted });
    expect(selected).toHaveLength(1);

    // pi still holds the clone this file selected, already at the capped window.
    // The comparison has to short-circuit before the routed lookup, which walks the
    // transcript, so a matching window costs one number per tick and nothing else.
    let usageReads = 0;
    const source: WatchdogSource = {
      ...unrouted,
      ui: silentUi,
      model: selected[0]!,
      getContextUsage: () => {
        usageReads += 1;
        return undefined;
      },
    };
    await watchdogTick(host, source);

    expect(selected).toHaveLength(1);
    expect(usageReads).toBe(0);
  });

  test("a tick with no model, and a tick after stopWatchdog, each do nothing", async () => {
    const settings = { contextWindowCap: 256000 };
    const selected: RuntimeModel[] = [];
    const setModel = async (model: RuntimeModel) => {
      selected.push(model);
      return true;
    };
    const handlers = loadContextCap(settings, setModel);
    const host = capHost(settings, setModel);

    await handlers.model_select({ model: pristineModel("watchdog-inert") }, { ui: silentUi, ...unrouted });
    expect(selected).toHaveLength(1);

    await watchdogTick(host, { ui: silentUi, ...unrouted });
    expect(selected).toHaveLength(1);

    stopWatchdog();
    await watchdogTick(host, { model: pristineModel("watchdog-inert"), ui: silentUi, ...unrouted });
    expect(selected).toHaveLength(1);
  });

  test("a tick while a re-selection is in flight does nothing", async () => {
    const settings = { contextWindowCap: 256000 };
    const selected: RuntimeModel[] = [];
    const model = pristineModel("watchdog-in-flight");
    let holding: RuntimeModel = model;
    let inFlightTick: Promise<void> | undefined;
    let replaced = false;
    const source: WatchdogSource = {
      ...unrouted,
      ui: silentUi,
      get model() {
        return holding;
      },
    };
    function setModel(selectedModel: RuntimeModel): Promise<boolean> {
      selected.push(selectedModel);
      // The re-selection is still awaiting this call, and pi can replace the model
      // during it, so the tick below would see a window that does not match. The
      // in-flight re-selection owns the model until it returns, so it must not.
      if (!replaced) {
        replaced = true;
        holding = pristineModel("watchdog-in-flight");
        inFlightTick = watchdogTick(host, source);
      }
      return Promise.resolve(true);
    }
    const host: CapHost = { setModel, getSettings: () => settings };
    const handlers = loadContextCap(settings, setModel);

    await handlers.model_select({ model }, { ui: silentUi, ...unrouted });

    expect(selected).toHaveLength(1);
    expect(inFlightTick).toBeUndefined();
  });

  test("startWatchdog followed by stopWatchdog leaves a tick inert, and a second stop does not throw", async () => {
    const settings = { contextWindowCap: 256000 };
    const selected: RuntimeModel[] = [];
    const setModel = async (model: RuntimeModel) => {
      selected.push(model);
      return true;
    };
    const handlers = loadContextCap(settings, setModel);
    const host = capHost(settings, setModel);

    await handlers.model_select({ model: pristineModel("watchdog-stopped") }, { ui: silentUi, ...unrouted });
    expect(selected).toHaveLength(1);

    startWatchdog(host, { model: pristineModel("watchdog-stopped"), ui: silentUi, ...unrouted });
    stopWatchdog();
    expect(() => stopWatchdog()).not.toThrow();

    await watchdogTick(host, { model: pristineModel("watchdog-stopped"), ui: silentUi, ...unrouted });
    expect(selected).toHaveLength(1);
  });

  test("a tick re-reads the source model, so a live source sees pi's replacement", async () => {
    const settings = { contextWindowCap: 256000 };
    const selected: RuntimeModel[] = [];
    const setModel = async (model: RuntimeModel) => {
      selected.push(model);
      return true;
    };
    const handlers = loadContextCap(settings, setModel);
    const host = capHost(settings, setModel);

    await handlers.model_select({ model: pristineModel("watchdog-live") }, { ui: silentUi, ...unrouted });
    expect(selected).toHaveLength(1);

    // The getter stands in for the extension context: pi holds the capped clone
    // first, then replaces it with a pristine registry model. A source that
    // snapshotted this value would keep returning the clone and stay inert.
    let holding: RuntimeModel = selected[0]!;
    const source: WatchdogSource = {
      ...unrouted,
      ui: silentUi,
      get model() {
        return holding;
      },
    };

    await watchdogTick(host, source);
    expect(selected).toHaveLength(1);

    holding = pristineModel("watchdog-live");
    await watchdogTick(host, source);
    expect(selected).toHaveLength(2);
    expect(selected[1]!.contextWindow).toBe(256000);
  });

  test("session_start hands the watchdog the live context, so a later replacement reaches a tick", async () => {
    const settings = { contextWindowCap: 256000 };
    const selected: RuntimeModel[] = [];
    const handlers = loadContextCap(settings, async (model) => {
      selected.push(model);
      return true;
    });
    // The getter is what the extension context provides: pi resolves ctx.model at
    // call time, so a source that copied it once would keep the old model.
    let holding: RuntimeModel = pristineModel("watchdog-wiring");
    const ctx = {
      ...unrouted,
      ui: silentUi,
      get model() {
        return holding;
      },
    };

    await handlers.session_start({ reason: "start" }, ctx);
    expect(selected).toHaveLength(1);
    expect(holding.contextWindow).toBe(256000);

    // pi swaps in a pristine registry model with no event, and the interval the
    // handler started has to notice it on its next tick.
    holding = pristineModel("watchdog-wiring");
    await Bun.sleep(WATCHDOG_INTERVAL_MS + 200);

    expect(selected.length).toBeGreaterThanOrEqual(2);
    expect(selected[selected.length - 1]!.contextWindow).toBe(256000);
  });
});
