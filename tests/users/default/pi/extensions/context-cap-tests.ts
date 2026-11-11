// Pure-function cases for the context-window extension. File IO and the pi
// API stay out of the tests; the extension keeps those in thin wrappers.

import { describe, expect, test } from "bun:test";
import {
  formatStatus,
  parseCommand,
  readCap,
  resolveWindow,
  setGlobalCap,
  setModelWindow,
  type ActiveModel,
  type Json,
} from "../../../../../src/users/default/pi/extensions/context-cap.ts";

const active: ActiveModel = { provider: "opencode-go", id: "glm-5.1" };

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
});

describe("resolveWindow", () => {
  test("session wins over everything", () => {
    expect(resolveWindow({ baseline: 1000000, session: 300000, cap: 256000 })).toEqual({
      window: 300000,
      source: "session",
    });
  });

  test("the ceiling applies only when the baseline is bigger", () => {
    expect(resolveWindow({ baseline: 1000000, session: null, cap: 256000 })).toEqual({
      window: 256000,
      source: "global",
    });
    expect(resolveWindow({ baseline: 100000, session: null, cap: 256000 })).toEqual({
      window: 100000,
      source: "native",
    });
  });

  test("no ceiling means the baseline", () => {
    expect(resolveWindow({ baseline: 200000, session: null, cap: null })).toEqual({
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
