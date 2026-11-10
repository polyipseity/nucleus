// pi context-window cap: one global ceiling from settings.json, explicit
// per-model windows from models.json, and a session-only runtime override.
// Precedence: session > models.json explicit > settings.json globalCap > native.
//
// Why mutation: pi exposes live Model objects (ModelSelectEvent.model,
// ExtensionContext.model) with a public contextWindow field and no setter.
// The footer percentage and the compaction trigger both read that field, so
// one write moves display and compaction together.
//
// Session-only: this file never writes settings.json or models.json. The
// session override lives in module scope and resets on reload.

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

export type WindowSource = "session" | "explicit" | "global" | "native";

export interface ContextLayers {
  native: number;
  explicit: number | null;
  globalCap: number | null;
  session: number | null;
}

export function computeContextWindow(layers: ContextLayers): {
  window: number;
  source: WindowSource;
} {
  if (layers.session !== null) return { window: layers.session, source: "session" };
  if (layers.explicit !== null) return { window: layers.explicit, source: "explicit" };
  if (layers.globalCap !== null && layers.native > layers.globalCap) {
    return { window: layers.globalCap, source: "global" };
  }
  return { window: layers.native, source: "native" };
}

// First sight of a model object records its pristine window, so repeated
// selections can never compound a previously applied cap.
const nativeCache = new WeakMap<object, number>();
let sessionOverride: number | null = null;

// Every `as` below follows an explicit runtime type guard on `unknown`.
function readGlobalCap(readSettings: () => unknown): number | null {
  const settings = readSettings();
  if (typeof settings !== "object" || settings === null) return null;
  const raw = (settings as { contextWindowCap?: unknown }).contextWindowCap;
  return typeof raw === "number" && Number.isFinite(raw) && raw > 0 ? raw : null;
}

// models.json layout: providers.<id>.models[] entries carry `id` plus an
// optional contextWindow, and providers.<id>.modelOverrides.<modelId>
// carries contextWindow. Any provider's entry for this model id counts as
// explicit: pi applies both forms before selection, and a missing or
// unreadable file simply means "no explicit layer".
function findExplicitWindow(modelId: string): number | null {
  let parsed: unknown;
  try {
    parsed = JSON.parse(readFileSync(join(homedir(), ".pi", "agent", "models.json"), "utf8"));
  } catch {
    return null;
  }
  if (typeof parsed !== "object" || parsed === null) return null;
  const providers = (parsed as { providers?: unknown }).providers;
  if (typeof providers !== "object" || providers === null) return null;
  for (const section of Object.values(providers)) {
    if (typeof section !== "object" || section === null) continue;
    const record = section as { models?: unknown; modelOverrides?: unknown };
    if (Array.isArray(record.models)) {
      for (const entry of record.models) {
        if (typeof entry !== "object" || entry === null) continue;
        const candidate = entry as { id?: unknown; contextWindow?: unknown };
        if (candidate.id === modelId && typeof candidate.contextWindow === "number") {
          return candidate.contextWindow;
        }
      }
    }
    const overrides = record.modelOverrides;
    if (typeof overrides === "object" && overrides !== null) {
      const override = (overrides as Record<string, unknown>)[modelId];
      if (typeof override === "object" && override !== null) {
        const window = (override as { contextWindow?: unknown }).contextWindow;
        if (typeof window === "number") return window;
      }
    }
  }
  return null;
}

export default function (pi: ExtensionAPI) {
  const getSettings = () => pi.getSettings();

  const applyCap = (model: { id: string; contextWindow: number }): void => {
    const native =
      nativeCache.get(model) ??
      (nativeCache.set(model, model.contextWindow), model.contextWindow);
    const result = computeContextWindow({
      native,
      explicit: findExplicitWindow(model.id),
      globalCap: readGlobalCap(getSettings),
      session: sessionOverride,
    });
    if (model.contextWindow !== result.window) model.contextWindow = result.window;
  };

  pi.on("model_select", ({ model }) => applyCap(model));
  pi.on("session_start", (_event, ctx) => {
    if (ctx.model) applyCap(ctx.model);
  });

  pi.registerCommand("context-window", {
    description: "Show or set the session context-window cap",
    handler: async (args, ctx) => {
      const model = ctx.model;
      if (!model) {
        ctx.ui.notify("no active model to size", "warning");
        return;
      }
      const arg = args.trim();
      if (arg === "") {
        const native = nativeCache.get(model) ?? model.contextWindow;
        const explicit = findExplicitWindow(model.id);
        const globalCap = readGlobalCap(getSettings);
        const result = computeContextWindow({
          native,
          explicit,
          globalCap,
          session: sessionOverride,
        });
        ctx.ui.notify(
          `context window: ${result.window} (${result.source}) for ${model.id}; ` +
            `layers: native ${native}, explicit ${explicit ?? "none"}, ` +
            `globalCap ${globalCap ?? "none"}, session ${sessionOverride ?? "none"}`,
          "info",
        );
        return;
      }
      if (arg === "default") {
        sessionOverride = null;
        applyCap(model);
        ctx.ui.notify(`session override cleared; ${model.id} uses its configured window`, "info");
        return;
      }
      if (/^[1-9][0-9]*$/.test(arg)) {
        sessionOverride = Number(arg);
        applyCap(model);
        ctx.ui.notify(
          `session context window for ${model.id} set to ${sessionOverride}; not saved anywhere`,
          "info",
        );
        return;
      }
      ctx.ui.notify("usage: /context-window [ <tokens> | default ]", "warning");
    },
  });
}
