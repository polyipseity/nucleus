// pi context-window control in two duties: enforce one global ceiling when a
// model is selected, and serve /context-window for status plus set and clear
// at four scopes. Model and provider windows are models.json entries that pi
// applies itself, so this file reads them only to report and writes them only
// on request. Precedence: session > explicit model window > global ceiling >
// native, so an explicit window always wins over the ceiling. Each `as` below
// narrows a value this file already checked with asObject or a string guard.

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { readFileSync, realpathSync, renameSync, rmSync, statSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { basename, dirname, join } from "node:path";

export type Scope = "session" | "model" | "provider" | "global";
export type Source = "session" | "model" | "global" | "native";
export type Json = Record<string, unknown>;

export interface ActiveModel {
  provider: string;
  id: string;
}

export type Command =
  | { kind: "status" }
  | { kind: "set"; scope: "session" | "global"; value: number }
  | { kind: "clear"; scope: "session" | "global" }
  | { kind: "set"; scope: "model"; value: number; provider: string; model: string }
  | { kind: "clear"; scope: "model"; provider: string; model: string }
  | { kind: "set"; scope: "provider"; value: number; provider: string }
  | { kind: "clear"; scope: "provider"; provider: string }
  | { kind: "error"; message: string };

export interface Layers {
  baseline: number;
  session: number | null;
  explicit: number | null;
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
export interface ModelCatalog {
  getAll(): readonly { provider: string; id: string }[];
}

export interface FilePaths {
  settings: string;
  models: string;
}

export type ApplyOutcome =
  | { kind: "none" }
  | { kind: "written"; target: "settings"; message: string; cap: number | null }
  | { kind: "written"; target: "models"; message: string }
  | { kind: "refused"; message: string };

export interface WindowInput {
  baseline: number;
  session: number | null;
  models: Json | null;
  settings: unknown;
}

const SCOPES: readonly string[] = ["session", "model", "provider", "global"];
const POSITIVE_INT = /^[1-9][0-9]*$/;
const GRAMMAR = "usage: /context-window [<n> | default | session|model|provider|global ...]";

function asObject(value: unknown): Json | null {
  if (typeof value !== "object" || value === null || Array.isArray(value)) return null;
  return value as Json;
}

function parsePositive(token: string | undefined): number | null {
  if (token === undefined || !POSITIVE_INT.test(token)) return null;
  const value = Number(token);
  return Number.isSafeInteger(value) ? value : null;
}

function parseTarget(token: string | undefined, active: ActiveModel): { provider: string; model: string } {
  if (token === undefined) return { provider: active.provider, model: active.id };
  const slash = token.indexOf("/");
  if (slash > 0 && slash < token.length - 1) {
    return { provider: token.slice(0, slash), model: token.slice(slash + 1) };
  }
  return { provider: active.provider, model: token };
}

export function parseCommand(input: string, active: ActiveModel): Command {
  const tokens = input.trim().split(/\s+/).filter((token) => token.length > 0);
  const [head, ...rest] = tokens;
  if (head === undefined) return { kind: "status" };

  if (!SCOPES.includes(head)) {
    const bare = parsePositive(head);
    if (bare !== null) return { kind: "set", scope: "session", value: bare };
    if (head === "default") return { kind: "clear", scope: "session" };
    return { kind: "error", message: `unknown scope "${head}". ${GRAMMAR}` };
  }

  const scope = head as Scope;

  if (scope === "session" || scope === "global") {
    if (rest.length !== 1) return { kind: "error", message: `${scope} takes one value. ${GRAMMAR}` };
    const value = parsePositive(rest[0]);
    if (value !== null) return { kind: "set", scope, value };
    if (rest[0] === "default") return { kind: "clear", scope };
    return { kind: "error", message: `${scope} needs a positive integer or default. ${GRAMMAR}` };
  }

  if (scope === "provider") {
    if (rest.length > 2) {
      return { kind: "error", message: `provider takes [<provider>] and a value or default. ${GRAMMAR}` };
    }
    const named = rest.length === 2 ? rest[0] : undefined;
    const provider = named === undefined ? active.provider : named;
    const last = rest.at(-1);
    if (last === "default") return { kind: "clear", scope, provider };
    const value = parsePositive(last);
    if (value === null) {
      return { kind: "error", message: `provider needs a positive integer or default. ${GRAMMAR}` };
    }
    return { kind: "set", scope, value, provider };
  }

  // A bare number in the id slot is not a model id, so `model 900000 500000`
  // is a malformed request rather than a model named after the number.
  if (rest.length === 2 && parsePositive(rest[0]) !== null) {
    return { kind: "error", message: `model takes a model id before the value. ${GRAMMAR}` };
  }
  const target = rest.length === 2 ? parseTarget(rest[0], active) : { provider: active.provider, model: active.id };
  const last = rest.at(-1);
  const value = parsePositive(last);
  if (value !== null && rest.length <= 2) return { kind: "set", scope, value, ...target };
  if (last === "default" && rest.length <= 2) return { kind: "clear", scope, ...target };
  return { kind: "error", message: `model takes [<id> | <provider>/<id>] and a value or default. ${GRAMMAR}` };
}

export function resolveWindow(layers: Layers): { window: number; source: Source } {
  if (layers.session !== null) return { window: layers.session, source: "session" };
  if (layers.explicit !== null) return { window: layers.explicit, source: "model" };
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

// Byte-stable output: sorted keys, 2-space indent, exactly one trailing newline.
export function serialize(value: unknown): string {
  return `${JSON.stringify(sortKeysDeep(value), null, 2)}\n`;
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

// A managed config file can be reached through a symlink or share its inode with
// a hardlink, and a plain rename breaks either one: it deletes the symlink, and it
// leaves a hardlink sibling on the old inode. Resolve the symlink first, then let
// the write choose a mechanism from the resolved file's link count.
function writableTarget(path: string): string {
  try {
    return realpathSync(path);
  } catch {
    return path;
  }
}

function describe(value: number | null): string {
  return value === null ? "cleared" : `set to ${value}`;
}

function writeJson(
  path: string,
  value: Json,
  written: Extract<ApplyOutcome, { kind: "written" }>,
): ApplyOutcome {
  const body = serialize(value);
  const resolved = writableTarget(path);
  const temporary = join(dirname(resolved), `.${basename(resolved)}.${process.pid}.tmp`);
  // throwIfNoEntry: a file that vanished between the read and the write has no
  // links to preserve, so it is written as a new one.
  const links = statSync(resolved, { throwIfNoEntry: false })?.nlink ?? 1;
  try {
    if (links > 1) {
      // WHY: replacing the name would leave every other hardlink on the old inode,
      // so a multiply linked file is written through its inode and is not atomic.
      writeFileSync(resolved, body, "utf8");
    } else {
      writeFileSync(temporary, body, "utf8");
      renameSync(temporary, resolved);
    }
  } catch (cause) {
    const failure = cause instanceof Error ? cause.message : String(cause);
    try {
      rmSync(temporary, { force: true });
    } catch (cleanup) {
      const leftover = cleanup instanceof Error ? cleanup.message : String(cleanup);
      return {
        kind: "refused",
        message: `cannot write ${resolved}: ${failure}; could not remove ${temporary}: ${leftover}`,
      };
    }
    return { kind: "refused", message: `cannot write ${resolved}: ${failure}` };
  }
  return written;
}

function modelWindow(models: Json | null, provider: string, modelId: string): number | null {
  const override = asObject(asObject(asObject(asObject(models?.providers)?.[provider])?.modelOverrides)?.[modelId]);
  const value = override?.contextWindow;
  return typeof value === "number" ? value : null;
}

// Effective window for one model, with the cap from the write mirror when a
// global write happened, and from `settings` otherwise.
export function effectiveWindow(model: ActiveModel, input: WindowInput): { window: number; source: Source } {
  return resolveWindow({
    baseline: input.baseline,
    session: input.session,
    explicit: modelWindow(input.models, model.provider, model.id),
    cap: resolveCap(input.settings),
  });
}

// Cap a write just produced, for the re-apply that follows it.
export function writtenCap(outcome: ApplyOutcome): number | null | undefined {
  return outcome.kind === "written" && outcome.target === "settings" ? outcome.cap : undefined;
}

// Cap the last global write produced, or undefined when none happened. pi builds
// its merged settings once and getSettings() returns a clone of that cache
// (settings-manager.js:305-307), so a later model switch would otherwise re-read
// the pre-write cap. A session_start for reason "reload" drops the mirror, since
// pi re-read the file then.
let capFromWrite: number | null | undefined;

export function noteWrittenCap(outcome: ApplyOutcome): void {
  const cap = writtenCap(outcome);
  if (cap !== undefined) capFromWrite = cap;
}

export function resetWrittenCap(): void {
  capFromWrite = undefined;
}

function resolveCap(settings: unknown): number | null {
  return capFromWrite === undefined ? readCap(settings) : capFromWrite;
}

// ids pi knows for a provider, plus the ids models.json lists or overrides, so
// a provider-scope write or clear also reaches a model pi has since dropped.
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
  const overrides = asObject(section?.modelOverrides);
  if (overrides) {
    for (const id of Object.keys(overrides)) ids.add(id);
  }
  return [...ids].sort();
}

export function applyToFiles(command: Command, paths: FilePaths, catalog: ModelCatalog): ApplyOutcome {
  if (command.kind !== "set" && command.kind !== "clear") return { kind: "none" };
  const value = command.kind === "set" ? command.value : null;

  switch (command.scope) {
    case "session":
      return { kind: "none" };
    case "global": {
      const settings = readJson(paths.settings);
      if (!settings) {
        return { kind: "refused", message: `${basename(paths.settings)} is missing or unreadable, nothing written` };
      }
      setGlobalCap(settings, value);
      return writeJson(paths.settings, settings, {
        kind: "written",
        target: "settings",
        message: `global window ${describe(value)}`,
        cap: value,
      });
    }
    case "model":
    case "provider":
      break;
  }

  const models = readJson(paths.models);
  if (!models) {
    return { kind: "refused", message: `${basename(paths.models)} is missing or unreadable, nothing written` };
  }
  const provider = command.provider;
  const ids = command.scope === "model" ? [command.model] : providerModelIds(catalog, provider, models);
  if (ids.length === 0) {
    return { kind: "refused", message: `no models found for provider ${provider}, nothing written` };
  }
  for (const id of ids) setModelWindow(models, provider, id, value);
  const plural = ids.length === 1 ? "" : "s";
  return writeJson(paths.models, models, {
    kind: "written",
    target: "models",
    message: `${command.scope} window ${describe(value)} for ${ids.length} model${plural} in ${provider}; run /model to reload models.json`,
  });
}

// Window a model carries on first sight, before any cap this file applied.
const nativeCache = new WeakMap<object, number>();
let sessionOverride: number | null = null;

export default function (pi: ExtensionAPI) {
  const settingsPath = join(agentDir(), "settings.json");
  const modelsPath = join(agentDir(), "models.json");
  const paths: FilePaths = { settings: settingsPath, models: modelsPath };

  const applyCap = (model: { provider: string; id: string; contextWindow: number }): void => {
    const cached = nativeCache.get(model);
    const baseline = cached ?? model.contextWindow;
    if (cached === undefined) nativeCache.set(model, baseline);
    const result = effectiveWindow(model, {
      baseline,
      session: sessionOverride,
      models: readJson(modelsPath),
      settings: pi.getSettings(),
    });
    if (model.contextWindow !== result.window) model.contextWindow = result.window;
  };

  pi.on("model_select", ({ model }) => applyCap(model));
  pi.on("session_start", (event, ctx) => {
    // A reload is the one point where pi re-reads settings.json, so its cache is
    // authoritative again and the mirror would only hold a stale copy.
    if (event.reason === "reload") resetWrittenCap();
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

      if (command.kind === "set" || command.kind === "clear") {
        const outcome = applyToFiles(command, paths, ctx.modelRegistry);
        if (outcome.kind === "refused") {
          ctx.ui.notify(outcome.message, "error");
          return;
        }
        if (outcome.kind === "written") ctx.ui.notify(outcome.message, "info");
        if (command.scope === "session") sessionOverride = command.kind === "set" ? command.value : null;
        // WHY: mirror the cap this command wrote instead of re-reading it. pi caches
        // its merged settings when SettingsManager is built and getSettings() returns
        // structuredClone of that cache (settings-manager.js:305-307), so the file
        // write only reaches pi.getSettings() when pi reloads; without the mirror the
        // next model switch would apply the pre-write cap.
        noteWrittenCap(outcome);
        applyCap(model);
      }

      const settings = readJson(settingsPath);
      const models = readJson(modelsPath);
      const baseline = nativeCache.get(model) ?? model.contextWindow;
      const sessions = sessionOverride;
      const caps = readCap(settings);
      const result = resolveWindow({
        baseline,
        session: sessions,
        explicit: modelWindow(models, active.provider, active.id),
        cap: caps,
      });
      const providerStatus = providerWindow(ctx.modelRegistry, active.provider, models);
      const activeOverride = modelWindow(models, active.provider, active.id);
      const lines = formatStatus({
        session: sessions,
        model: activeOverride,
        provider: providerStatus,
        global: caps,
        baseline,
        effective: result.window,
        source: result.source,
      });
      ctx.ui.notify(lines.join("\n"), "info");
    },
  });
}

function providerWindow(
  catalog: ModelCatalog,
  provider: string,
  models: Json | null,
): { value: number; count: number } | "mixed" | null {
  const ids = providerModelIds(catalog, provider, models);
  if (ids.length === 0) return null;
  const values = ids.map((id) => modelWindow(models, provider, id));
  const set = values.filter((value): value is number => value !== null);
  const [first] = set;
  if (first === undefined) return null;
  return set.length === ids.length && set.every((value) => value === first)
    ? { value: first, count: ids.length }
    : "mixed";
}
