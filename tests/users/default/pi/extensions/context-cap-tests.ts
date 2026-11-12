// Cases for the context-window extension: pure parsing and precedence, the
// deterministic serializer, and file round-trips against a temp directory so
// the session command's writes are exercised without touching ~/.pi.

import { afterEach, describe, expect, test } from "bun:test";
import { existsSync, lstatSync, linkSync, mkdtempSync, readFileSync, statSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import {
  applyToFiles,
  effectiveWindow,
  formatFullStatus,
  formatScopeStatus,
  noteWrittenCap,
  parseCommand,
  providerWindow,
  readCap,
  resetWrittenCap,
  resolveWindow,
  serialize,
  setGlobalCap,
  setModelWindow,
  syncModelWindow,
  type ActiveModel,
  type FilePaths,
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
