// Cases for the context-window extension: pure parsing and precedence, the
// deterministic serializer, and file round-trips against a temp directory so
// the session command's writes are exercised without touching ~/.pi.

import { afterEach, describe, expect, test } from "bun:test";
import { existsSync, lstatSync, mkdtempSync, readFileSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import {
  applyToFiles,
  effectiveWindow,
  formatStatus,
  noteWrittenCap,
  parseCommand,
  readCap,
  resetWrittenCap,
  resolveWindow,
  serialize,
  setGlobalCap,
  setModelWindow,
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
  test("empty input asks for status", () => {
    expect(parseCommand("", active)).toEqual({ kind: "status" });
  });

  test("a bare number sets the session window", () => {
    expect(parseCommand("200000", active)).toEqual({ kind: "set", scope: "session", value: 200000 });
  });

  test("default clears the session window", () => {
    expect(parseCommand("default", active)).toEqual({ kind: "clear", scope: "session" });
  });

  test("global takes a value or default", () => {
    expect(parseCommand("global 256000", active)).toEqual({ kind: "set", scope: "global", value: 256000 });
    expect(parseCommand("global default", active)).toEqual({ kind: "clear", scope: "global" });
  });

  test("model defaults to the active model", () => {
    expect(parseCommand("model 900000", active)).toEqual({
      kind: "set",
      scope: "model",
      value: 900000,
      provider: "opencode-go",
      model: "glm-5.1",
    });
  });

  test("model accepts provider/id", () => {
    expect(parseCommand("model anthropic/claude-sonnet-5 500000", active)).toEqual({
      kind: "set",
      scope: "model",
      value: 500000,
      provider: "anthropic",
      model: "claude-sonnet-5",
    });
  });

  test("provider defaults to the active provider", () => {
    expect(parseCommand("provider 200000", active)).toEqual({
      kind: "set",
      scope: "provider",
      value: 200000,
      provider: "opencode-go",
    });
  });

  test("rejects zero, negatives, and junk", () => {
    for (const input of ["0", "-5", "session 0", "nonsense", "model abc"]) {
      expect(parseCommand(input, active).kind).toBe("error");
    }
  });

  test("rejects a number in the model id slot", () => {
    for (const input of ["model 900000 500000", "model 900000 default"]) {
      expect(parseCommand(input, active).kind).toBe("error");
    }
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
    noteWrittenCap(applyToFiles(parseCommand("global 100000", active), paths, catalog));
    expect(effectiveWindow(active, { ...base, settings: staleSettings })).toEqual({
      window: 100000,
      source: "global",
    });
    // A second resolution stands in for the next model switch, where pi's cache
    // still reports its construction-time cap.
    expect(effectiveWindow(active, { ...base, settings: { contextWindowCap: 999 } }).window).toBe(100000);
  });

  test("clearing keeps the cap gone, and a reload restores pi's value", () => {
    resetWrittenCap();
    const paths = tempPaths({ settings: '{"contextWindowCap":256000}\n' });
    noteWrittenCap(applyToFiles(parseCommand("global default", active), paths, catalog));
    expect(effectiveWindow(active, { ...base, settings: staleSettings })).toEqual({
      window: 1000000,
      source: "native",
    });
    // A session_start for reason "reload" drops the mirror, so pi reports again.
    resetWrittenCap();
    expect(effectiveWindow(active, { ...base, settings: staleSettings })).toEqual({
      window: 256000,
      source: "global",
    });
  });

  test("a models.json write leaves the cap mirror alone", () => {
    resetWrittenCap();
    const paths = tempPaths({ models: "{}\n" });
    noteWrittenCap(applyToFiles(parseCommand("model 500000", active), paths, catalog));
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

describe("formatStatus", () => {
  test("prints one line per scope and the effective window", () => {
    expect(
      formatStatus({
        session: null,
        model: 500000,
        provider: "mixed",
        global: 256000,
        baseline: 1000000,
        effective: 256000,
        source: "global",
      }),
    ).toEqual([
      "session   unset",
      "model     500000",
      "provider  mixed",
      "global    256000",
      "effective 256000 (global) of 1000000 native",
    ]);
  });
});

describe("applyToFiles", () => {
  test("global set writes a sorted cap with one trailing newline", () => {
    const paths = tempPaths({
      settings: '{"compact":true,"$schema":"https://example.invalid/settings.json"}\n',
    });
    const outcome = applyToFiles(parseCommand("global 256000", active), paths, catalog);
    expect(outcome.kind).toBe("written");
    expect(readFileSync(paths.settings, "utf8")).toBe(
      '{\n  "$schema": "https://example.invalid/settings.json",\n  "compact": true,\n  "contextWindowCap": 256000\n}\n',
    );
  });

  test("global clear removes only the cap", () => {
    const paths = tempPaths({
      settings: '{"$schema":"https://example.invalid/settings.json","contextWindowCap":256000,"defaultProvider":"opencode-go"}\n',
    });
    expect(applyToFiles(parseCommand("global default", active), paths, catalog).kind).toBe("written");
    expect(JSON.parse(readFileSync(paths.settings, "utf8"))).toEqual({
      $schema: "https://example.invalid/settings.json",
      defaultProvider: "opencode-go",
    });
  });

  test("model set creates the provider section", () => {
    const paths = tempPaths({ models: "{}\n" });
    expect(
      applyToFiles(parseCommand("model anthropic/claude-sonnet-5 500000", active), paths, catalog).kind,
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
    expect(applyToFiles(parseCommand("provider anthropic 200000", active), paths, catalog).kind).toBe("written");
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
    expect(applyToFiles(parseCommand("model anthropic/claude-sonnet-5 default", active), paths, catalog).kind).toBe(
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
    for (const input of ["global 256000", "model 500000", "provider 200000"]) {
      const outcome = applyToFiles(parseCommand(input, active), paths, catalog);
      expect(outcome.kind).toBe("refused");
      expect(existsSync(paths.settings)).toBe(false);
      expect(existsSync(paths.models)).toBe(false);
    }
  });

  test("an unparsable file is left untouched", () => {
    const paths = tempPaths({ settings: "{not json", models: "{not json" });
    for (const input of ["global 256000", "model 500000"]) {
      expect(applyToFiles(parseCommand(input, active), paths, catalog).kind).toBe("refused");
    }
    expect(readFileSync(paths.settings, "utf8")).toBe("{not json");
    expect(readFileSync(paths.models, "utf8")).toBe("{not json");
  });

  test("a provider with no known models writes nothing", () => {
    const paths = tempPaths({ models: "{}\n" });
    const outcome = applyToFiles(parseCommand("provider nobody 200000", active), paths, catalog);
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
    expect(applyToFiles(parseCommand("global 256000", active), paths, catalog).kind).toBe("written");
    expect(lstatSync(paths.settings).isSymbolicLink()).toBe(true);
    expect(readFileSync(target, "utf8")).toBe('{\n  "contextWindowCap": 256000\n}\n');
  });
});
