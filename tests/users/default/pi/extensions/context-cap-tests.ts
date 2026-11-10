import { describe, expect, test } from "bun:test";
import {
  computeContextWindow,
  type ContextLayers,
} from "../../../../../src/users/default/pi/extensions/context-cap.ts";

const native = 1000000;
const global256k = 256000;

function layers(overrides: Partial<ContextLayers> = {}): ContextLayers {
  return { native, explicit: null, globalCap: global256k, session: null, ...overrides };
}

describe("computeContextWindow precedence", () => {
  test("native below the global cap stays native", () => {
    expect(computeContextWindow(layers({ native: 128000 }))).toEqual({
      window: 128000,
      source: "native",
    });
  });

  test("native above the global cap is lowered to the cap", () => {
    expect(computeContextWindow(layers())).toEqual({ window: global256k, source: "global" });
  });

  test("a null global cap leaves the native window untouched", () => {
    expect(computeContextWindow(layers({ globalCap: null }))).toEqual({
      window: native,
      source: "native",
    });
  });

  test("an explicit model window below the global cap still wins", () => {
    expect(computeContextWindow(layers({ explicit: 100000 }))).toEqual({
      window: 100000,
      source: "explicit",
    });
  });

  test("an explicit model window can raise above the global cap", () => {
    expect(computeContextWindow(layers({ explicit: 512000 }))).toEqual({
      window: 512000,
      source: "explicit",
    });
  });

  test("a session override beats explicit, global, and native", () => {
    expect(computeContextWindow(layers({ explicit: 512000, session: 900000 }))).toEqual({
      window: 900000,
      source: "session",
    });
  });

  test("no configured layer anywhere falls back to native", () => {
    expect(
      computeContextWindow({ native: 200000, explicit: null, globalCap: null, session: null }),
    ).toEqual({ window: 200000, source: "native" });
  });
});
