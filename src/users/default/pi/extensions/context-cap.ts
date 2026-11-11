// pi context-window control in two duties: enforce one global ceiling when a
// model is selected, and serve /context-window for status plus set and clear
// at four scopes. Model and provider windows are models.json entries that pi
// applies itself, so this file reads them only to report and writes them only
// on request. Precedence: session > model > provider > global > native. Each
// `as` below narrows a value this file already checked with asObject or a
// string guard.

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { readFileSync, renameSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";

export type Scope = "session" | "model" | "provider" | "global";
export type Source = "session" | "global" | "native";
export type Json = Record<string, unknown>;

export interface ActiveModel {
  provider: string;
  id: string;
}

export type Command =
  | { kind: "status" }
  | { kind: "set"; scope: Scope; value: number; provider?: string; model?: string }
  | { kind: "clear"; scope: Scope; provider?: string; model?: string }
  | { kind: "error"; message: string };

export interface Layers {
  baseline: number;
  session: number | null;
  cap: number | null;
}

export interface StatusInput {
  session: number | null;
  model: number | null;
  provider: { value: number; count: number } | "mixed" | null;
  global: number | null;
  baseline: number;
  effective: number;
  source: Source;
}

// The extension API exposes no model catalog: modelRegistry lives on the
// extension context that pi hands to handlers, so callers pass that.
interface ModelCatalog {
  getAll(): readonly { provider: string; id: string }[];
}

const SCOPES: readonly string[] = ["session", "model", "provider", "global"];
const POSITIVE_INT = /^[1-9][0-9]*$/;
const GRAMMAR = "usage: /context-window [<n> | default | session|model|provider|global ...]";

function asObject(value: unknown): Json | null {
  if (typeof value !== "object" || value === null || Array.isArray(value)) return null;
  return value as Json;
}

function parsePositive(token: string): number | null {
  if (!POSITIVE_INT.test(token)) return null;
  const value = Number(token);
  return Number.isSafeInteger(value) ? value : null;
}

function parseTarget(token: string, active: ActiveModel): { provider: string; model: string } {
  const slash = token.indexOf("/");
  if (slash > 0 && slash < token.length - 1) {
    return { provider: token.slice(0, slash), model: token.slice(slash + 1) };
  }
  return { provider: active.provider, model: token };
}

export function parseCommand(input: string, active: ActiveModel): Command {
  const tokens = input.trim().split(/\s+/).filter((token) => token.length > 0);
  if (tokens.length === 0) return { kind: "status" };

  const head = tokens[0];
  if (!SCOPES.includes(head)) {
    const bare = parsePositive(head);
    if (bare !== null) return { kind: "set", scope: "session", value: bare };
    if (head === "default") return { kind: "clear", scope: "session" };
    return { kind: "error", message: `unknown scope "${head}". ${GRAMMAR}` };
  }

  const scope = head as Scope;
  const rest = tokens.slice(1);

  if (scope === "session" || scope === "global") {
    if (rest.length !== 1) return { kind: "error", message: `${scope} takes one value. ${GRAMMAR}` };
    const value = parsePositive(rest[0]);
    if (value !== null) return { kind: "set", scope, value };
    if (rest[0] === "default") return { kind: "clear", scope };
    return { kind: "error", message: `${scope} needs a positive integer or default. ${GRAMMAR}` };
  }

  if (scope === "provider") {
    const value = rest.length > 0 ? parsePositive(rest[rest.length - 1]) : null;
    const isClear = rest.length > 0 && rest[rest.length - 1] === "default";
    if ((value === null && !isClear) || rest.length > 2) {
      return { kind: "error", message: `provider takes [<provider>] and a value or default. ${GRAMMAR}` };
    }
    const provider = rest.length === 2 ? rest[0] : active.provider;
    return isClear
      ? { kind: "clear", scope, provider }
      : { kind: "set", scope, value: value as number, provider };
  }

  const target = rest.length === 2 ? parseTarget(rest[0], active) : { provider: active.provider, model: active.id };
  const last = rest.length > 0 ? rest[rest.length - 1] : "";
  const value = parsePositive(last);
  if (value !== null && rest.length <= 2) return { kind: "set", scope, value, ...target };
  if (last === "default" && rest.length <= 2) return { kind: "clear", scope, ...target };
  return { kind: "error", message: `model takes [<id> | <provider>/<id>] and a value or default. ${GRAMMAR}` };
}

export function resolveWindow(layers: Layers): { window: number; source: Source } {
  if (layers.session !== null) return { window: layers.session, source: "session" };
  if (layers.cap !== null && layers.baseline > layers.cap) return { window: layers.cap, source: "global" };
  return { window: layers.baseline, source: "native" };
}

export function readCap(settings: unknown): number | null {
  const object = asObject(settings);
  if (!object) return null;
  const raw = object.contextWindowCap;
  return typeof raw === "number" && Number.isFinite(raw) && raw > 0 ? raw : null;
}

export function setGlobalCap(settings: Json, value: number | null): void {
  if (value === null) {
    delete settings.contextWindowCap;
    return;
  }
  settings.contextWindowCap = value;
}

export function setModelWindow(models: Json, provider: string, modelId: string, value: number | null): void {
  let providers = asObject(models.providers);
  if (!providers) {
    if (value === null) return;
    providers = {};
    models.providers = providers;
  }
  let section = asObject(providers[provider]);
  if (!section) {
    if (value === null) return;
    section = {};
    providers[provider] = section;
  }
  let overrides = asObject(section.modelOverrides);
  if (value === null) {
    if (!overrides) return;
    const entry = asObject(overrides[modelId]);
    if (entry) {
      delete entry.contextWindow;
      if (Object.keys(entry).length === 0) delete overrides[modelId];
    }
    if (Object.keys(overrides).length === 0) delete section.modelOverrides;
    if (Object.keys(section).length === 0) delete providers[provider];
    return;
  }
  if (!overrides) {
    overrides = {};
    section.modelOverrides = overrides;
  }
  const entry = asObject(overrides[modelId]) ?? {};
  entry.contextWindow = value;
  overrides[modelId] = entry;
}

export function formatStatus(input: StatusInput): string[] {
  const text = (value: number | null): string => (value === null ? "unset" : String(value));
  const provider =
    input.provider === null
      ? "unset"
      : input.provider === "mixed"
        ? "mixed"
        : `${input.provider.value} (${input.provider.count} models)`;
  return [
    `session   ${text(input.session)}`,
    `model     ${text(input.model)}`,
    `provider  ${provider}`,
    `global    ${text(input.global)}`,
    `effective ${input.effective} (${input.source}) of ${input.baseline} native`,
  ];
}

function sortKeysDeep(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(sortKeysDeep);
  const object = asObject(value);
  if (!object) return value;
  const sorted: Json = {};
  for (const key of Object.keys(object).sort()) sorted[key] = sortKeysDeep(object[key]);
  return sorted;
}

function agentDir(): string {
  return join(homedir(), ".pi", "agent");
}

function readJson(path: string): Json | null {
  try {
    return asObject(JSON.parse(readFileSync(path, "utf8")) as unknown);
  } catch {
    return null;
  }
}

function writeJson(path: string, value: Json): void {
  const body = `${JSON.stringify(sortKeysDeep(value), null, 2)}\n`;
  const temporary = join(dirname(path), `.${process.pid}.tmp`);
  writeFileSync(temporary, body, "utf8");
  renameSync(temporary, path);
}

// Window a model carries on first sight, before any cap this file applied.
const nativeCache = new WeakMap<object, number>();
let sessionOverride: number | null = null;

export default function (pi: ExtensionAPI) {
  const applyCap = (model: { id: string; contextWindow: number }): void => {
    const cached = nativeCache.get(model);
    const baseline = cached ?? model.contextWindow;
    if (cached === undefined) nativeCache.set(model, baseline);
    const result = resolveWindow({ baseline, session: sessionOverride, cap: readCap(pi.getSettings()) });
    if (model.contextWindow !== result.window) model.contextWindow = result.window;
  };

  pi.on("model_select", ({ model }) => applyCap(model));
  pi.on("session_start", (_event, ctx) => {
    if (ctx.model) applyCap(ctx.model);
  });

  pi.registerCommand("context-window", {
    description: "Show or change the context window at session, model, provider, or global scope",
    handler: async (args, ctx) => {
      const model = ctx.model;
      if (!model) {
        ctx.ui.notify("no active model to size", "warning");
        return;
      }
      const active: ActiveModel = { provider: model.provider, id: model.id };
      const command = parseCommand(args, active);
      if (command.kind === "error") {
        ctx.ui.notify(command.message, "error");
        return;
      }

      const settingsPath = join(agentDir(), "settings.json");
      const modelsPath = join(agentDir(), "models.json");

      if (command.kind === "set" || command.kind === "clear") {
        const value = command.kind === "set" ? command.value : null;
        if (command.scope === "session") {
          sessionOverride = value;
          applyCap(model);
        } else if (command.scope === "global") {
          const settings = readJson(settingsPath);
          if (!settings) {
            ctx.ui.notify("settings.json is missing or unreadable, nothing written", "error");
            return;
          }
          setGlobalCap(settings, value);
          writeJson(settingsPath, settings);
          applyCap(model);
        } else {
          const models = readJson(modelsPath);
          if (!models) {
            ctx.ui.notify("models.json is missing or unreadable, nothing written", "error");
            return;
          }
          const provider = command.provider as string;
          const ids =
            command.scope === "model"
              ? [command.model as string]
              : providerModelIds(ctx.modelRegistry, provider, models);
          if (ids.length === 0) {
            ctx.ui.notify(`no models found for provider ${provider}, nothing written`, "error");
            return;
          }
          for (const id of ids) setModelWindow(models, provider, id, value);
          writeJson(modelsPath, models);
          ctx.ui.notify(`${command.scope} window ${value === null ? "cleared" : `set to ${value}`}; run /model or restart to load it`, "info");
        }
      }

      const settings = readJson(settingsPath);
      const models = readJson(modelsPath);
      const baseline = nativeCache.get(model) ?? model.contextWindow;
      const sessions = sessionOverride;
      const caps = readCap(settings);
      const result = resolveWindow({ baseline, session: sessions, cap: caps });
      const providerStatus = providerWindow(ctx.modelRegistry, active.provider, models);
      const activeOverride = modelWindow(models, active.provider, active.id);
      for (const line of formatStatus({
        session: sessions,
        model: activeOverride,
        provider: providerStatus,
        global: caps,
        baseline,
        effective: result.window,
        source: result.source,
      })) {
        ctx.ui.notify(line, "info");
      }
    },
  });
}

function providerModelIds(catalog: ModelCatalog, provider: string, models: Json | null): string[] {
  const ids = new Set<string>();
  for (const model of catalog.getAll()) {
    if (model.provider === provider) ids.add(model.id);
  }
  const section = asObject(asObject(models?.providers)?.[provider]);
  const listed = section?.models;
  if (Array.isArray(listed)) {
    for (const entry of listed) {
      const id = asObject(entry)?.id;
      if (typeof id === "string") ids.add(id);
    }
  }
  return [...ids].sort();
}

function modelWindow(models: Json | null, provider: string, modelId: string): number | null {
  const override = asObject(asObject(asObject(asObject(models?.providers)?.[provider])?.modelOverrides)?.[modelId]);
  const value = override?.contextWindow;
  return typeof value === "number" ? value : null;
}

function providerWindow(
  catalog: ModelCatalog,
  provider: string,
  models: Json | null,
): { value: number; count: number } | "mixed" | null {
  const ids = providerModelIds(catalog, provider, models);
  if (ids.length === 0) return null;
  const values = ids.map((id) => modelWindow(models, provider, id));
  if (values.every((value) => value === null)) return null;
  const set = values.filter((value): value is number => value !== null);
  return set.length === ids.length && set.every((value) => value === set[0])
    ? { value: set[0], count: ids.length }
    : "mixed";
}
