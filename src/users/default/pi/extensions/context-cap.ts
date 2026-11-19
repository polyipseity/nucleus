// pi context-window control in three duties: enforce one global ceiling when a
// model is selected, serve /context-window for status plus set and clear at
// four scopes, and re-select the model when the effective window changes so the
// user's footer recomputes it. Model and provider windows are models.json
// entries that pi applies itself, so this file reads them only to report and
// writes them only on request. Client precedence: session > explicit model
// window > global ceiling > native. The server context limit is read-only
// (live probe, then models-store.json, else unset) and clamps the effective
// window to min(client, server). Each `as` below narrows a value this file
// already checked with asObject or a string guard. This extension installs no
// footer of its own: the footer belongs to the user's pi-powerline-footer
// package, whose component is single-owner.

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { mkdirSync, readFileSync, realpathSync, renameSync, rmSync, statSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { basename, dirname, join } from "node:path";

let resolveAgentDir: () => string;
try {
  const mod = await import("@earendil-works/pi-coding-agent");
  resolveAgentDir = mod.getAgentDir;
} catch {
  // WHY: tests run outside pi's extension loader and cannot resolve the package
  // specifier; PI_CODING_AGENT_DIR is the documented override and homedir is the
  // default, matching pi's config behavior for this path.
  resolveAgentDir = () => process.env.PI_CODING_AGENT_DIR || join(homedir(), ".pi", "agent");
}

export type Scope = "session" | "model" | "provider" | "global";
export type StatusScope = "all" | Scope;
export type Source = "session" | "model" | "global" | "native" | "server";
export type ServerSource = "live" | "store" | "unset";
export interface ServerWindow {
  value: number | null;
  source: ServerSource;
  reason?: string;
}
export type Json = Record<string, unknown>;

export interface ActiveModel {
  provider: string;
  id: string;
}

export interface RuntimeModel {
  provider: string;
  id: string;
  contextWindow: number;
}

export interface StatusUi {
  setStatus(key: string, value: string | undefined): void;
}

export interface CapUi extends StatusUi {
  notify(message: string, type?: "info" | "warning" | "error"): void;
}

export type Command =
  | { kind: "status"; scope: "all" | "session" | "global" }
  | { kind: "status"; scope: "model"; provider: string; model: string }
  | { kind: "status"; scope: "provider"; provider: string }
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

export type ProviderStatus = { value: number; count: number } | "mixed" | null;

export interface FullStatusInput {
  session: number | null;
  model: number | null;
  provider: ProviderStatus;
  global: number | null;
  server: ServerWindow;
  effective: number;
  source: Source;
  clientWindow: number;
  clientSource: Exclude<Source, "server">;
  native: number;
}

// The extension API exposes no model catalog: modelRegistry lives on the
// extension context that pi hands to handlers, so callers pass that.
export interface ModelCatalog {
  getAll(): readonly { provider: string; id: string }[];
}

// pi.setModel takes a whole model, while this file knows only the provider, id,
// and window, so callers pass just the one method a re-selection needs.
export interface ModelSelector {
  setModel(model: RuntimeModel): Promise<boolean>;
}

// A re-apply resolves the cap from pi's merged settings and re-selects through
// the same handle, so it takes both methods from one object. The extension API
// and this file's tests each supply them.
export interface CapHost extends ModelSelector {
  getSettings(): unknown;
}

export interface FilePaths {
  settings: string;
  models: string;
}

// A routed selection displays the registry's physical model window (agent-session.js:1020-1027,
// model-runtime.js:753-756), so callers pass the parts of the extension context that reach it.
export interface RoutedSource {
  sessionManager: { getEntries(): readonly unknown[] };
  modelRegistry: { find(provider: string, modelId: string): RuntimeModel | undefined };
  getContextUsage(): { contextWindow: number } | undefined;
}

// What a watchdog tick reads: the routed parts of the extension context plus the
// model pi is holding. Both properties are readonly because a tick has to read
// agent.state.model again on every pass, so callers pass the live context and
// never a copy of it: a spread would snapshot `model` once and the tick could
// then never see the registry replacement it watches for.
export interface WatchdogSource extends RoutedSource {
  readonly model?: RuntimeModel;
  readonly ui?: CapUi;
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
  server?: number | null;
}

const SCOPES = new Set<Scope>(["session", "model", "provider", "global"]);
const POSITIVE_INT = /^[1-9][0-9]*$/;
const NEGATIVE_INT = /^-\d+$/;
const DIGITS = /^\d+$/;
const GRAMMAR =
  "usage: /context-window [all|session|model [M]|provider [P]|global | N [scope]|N model [M]|N provider [P]|N global | default|<negative> [same scope/target]]";
const POSITIVE_WINDOW_ERROR = `context window must be a positive integer. ${GRAMMAR}`;

function asObject(value: unknown): Json | null {
  if (typeof value !== "object" || value === null || Array.isArray(value)) return null;
  return value as Json;
}

function parsePositive(token: string | undefined): number | null {
  if (token === undefined || !POSITIVE_INT.test(token)) return null;
  const value = Number(token);
  return Number.isSafeInteger(value) ? value : null;
}

// "-0" is the number zero and zero is not a valid window, so it errors like
// "0" instead of clearing like the other negative values.
function isClearValue(token: string | undefined): boolean {
  return token === "default" || (token !== undefined && NEGATIVE_INT.test(token) && Number(token) < 0);
}

// A token written as a plain number that parsePositive rejected, such as "0",
// "-0", or "007".
function isWindowNumber(token: string): boolean {
  return DIGITS.test(token) || NEGATIVE_INT.test(token);
}

// Split on the first slash only: providers publish multi-slash ids such as
// meta-llama/Llama-3-70b, so a/b/c is provider a and model b/c. An empty
// provider or model half is a malformed target, not a literal model id.
function parseModelTarget(
  token: string | undefined,
  active: ActiveModel,
): { provider: string; model: string } | null {
  if (token === undefined) return { provider: active.provider, model: active.id };
  const slash = token.indexOf("/");
  if (slash === -1) return { provider: active.provider, model: token };
  const provider = token.slice(0, slash);
  const model = token.slice(slash + 1);
  if (provider.length === 0 || model.length === 0) return null;
  return { provider, model };
}

// A provider name has no slash, so a slash means the token named a
// provider/model pair that only a model target accepts.
function parseProviderTarget(token: string | undefined, active: ActiveModel): string | null {
  if (token === undefined) return active.provider;
  return token.includes("/") ? null : token;
}

function isScope(token: string): token is Scope {
  return SCOPES.has(token as Scope);
}

export function parseCommand(input: string, active: ActiveModel): Command {
  const tokens = input.trim().split(/\s+/).filter((token) => token.length > 0);
  const [head, ...rest] = tokens;
  if (head === undefined || head === "all") {
    if (rest.length !== 0) return { kind: "error", message: `all takes no arguments. ${GRAMMAR}` };
    return { kind: "status", scope: "all" };
  }

  const value = parsePositive(head);
  if (value !== null) {
    const scopeToken = rest[0];
    if (scopeToken === undefined || scopeToken === "session") {
      if (rest.length > 1) return { kind: "error", message: `session takes no target. ${GRAMMAR}` };
      return { kind: "set", scope: "session", value };
    }
    if (scopeToken === "global") {
      if (rest.length !== 1) return { kind: "error", message: `global takes no target. ${GRAMMAR}` };
      return { kind: "set", scope: "global", value };
    }
    if (scopeToken === "model") {
      if (rest.length > 2) return { kind: "error", message: `model takes at most one target. ${GRAMMAR}` };
      const target = parseModelTarget(rest[1], active);
      if (target === null) return { kind: "error", message: `invalid model target "${rest[1]}". ${GRAMMAR}` };
      return { kind: "set", scope: "model", value, ...target };
    }
    if (scopeToken === "provider") {
      if (rest.length > 2) return { kind: "error", message: `provider takes at most one target. ${GRAMMAR}` };
      const provider = parseProviderTarget(rest[1], active);
      if (provider === null) return { kind: "error", message: `invalid provider target "${rest[1]}". ${GRAMMAR}` };
      return { kind: "set", scope: "provider", value, provider };
    }
    return { kind: "error", message: `unknown scope "${scopeToken}". ${GRAMMAR}` };
  }

  if (isClearValue(head)) {
    const scopeToken = rest[0];
    if (scopeToken === undefined || scopeToken === "session") {
      if (rest.length > 1) return { kind: "error", message: `session takes no target. ${GRAMMAR}` };
      return { kind: "clear", scope: "session" };
    }
    if (scopeToken === "global") {
      if (rest.length !== 1) return { kind: "error", message: `global takes no target. ${GRAMMAR}` };
      return { kind: "clear", scope: "global" };
    }
    if (scopeToken === "model") {
      if (rest.length > 2) return { kind: "error", message: `model takes at most one target. ${GRAMMAR}` };
      const target = parseModelTarget(rest[1], active);
      if (target === null) return { kind: "error", message: `invalid model target "${rest[1]}". ${GRAMMAR}` };
      return { kind: "clear", scope: "model", ...target };
    }
    if (scopeToken === "provider") {
      if (rest.length > 2) return { kind: "error", message: `provider takes at most one target. ${GRAMMAR}` };
      const provider = parseProviderTarget(rest[1], active);
      if (provider === null) return { kind: "error", message: `invalid provider target "${rest[1]}". ${GRAMMAR}` };
      return { kind: "clear", scope: "provider", provider };
    }
    return { kind: "error", message: `unknown scope "${scopeToken}". ${GRAMMAR}` };
  }

  if (isWindowNumber(head)) return { kind: "error", message: POSITIVE_WINDOW_ERROR };

  if (!isScope(head)) {
    return { kind: "error", message: `unknown command "${head}". ${GRAMMAR}` };
  }

  if (head === "session" || head === "global") {
    if (rest.length !== 0) return { kind: "error", message: `${head} query takes no arguments. ${GRAMMAR}` };
    return { kind: "status", scope: head };
  }

  if (head === "provider") {
    if (rest.length > 1) return { kind: "error", message: `provider query takes at most one target. ${GRAMMAR}` };
    const provider = parseProviderTarget(rest[0], active);
    if (provider === null) return { kind: "error", message: `invalid provider target "${rest[0]}". ${GRAMMAR}` };
    return { kind: "status", scope: "provider", provider };
  }

  if (rest.length > 1) return { kind: "error", message: `model query takes at most one target. ${GRAMMAR}` };
  const target = parseModelTarget(rest[0], active);
  if (target === null) return { kind: "error", message: `invalid model target "${rest[0]}". ${GRAMMAR}` };
  return { kind: "status", scope: "model", ...target };
}

export interface ResolvedWindow {
  window: number;
  source: Source;
  clientWindow: number;
  clientSource: Exclude<Source, "server">;
}

function resolveClientWindow(layers: Layers): { window: number; source: Exclude<Source, "server"> } {
  if (layers.session !== null) return { window: layers.session, source: "session" };
  if (layers.explicit !== null) return { window: layers.explicit, source: "model" };
  if (layers.cap !== null && layers.baseline > layers.cap) return { window: layers.cap, source: "global" };
  return { window: layers.baseline, source: "native" };
}

export function resolveWindow(layers: Layers & { server?: number | null }): ResolvedWindow {
  const client = resolveClientWindow(layers);
  const server = layers.server ?? null;
  if (server !== null && server < client.window) {
    return { window: server, source: "server", clientWindow: client.window, clientSource: client.source };
  }
  return { window: client.window, source: client.source, clientWindow: client.window, clientSource: client.source };
}

export function readCap(settings: unknown): number | null {
  const object = asObject(settings);
  if (!object) return null;
  const raw = object.contextWindowCap;
  return typeof raw === "number" && Number.isFinite(raw) && raw > 0 ? raw : null;
}

export const DEFAULT_GLOBAL_CAP: number | null = null;

export function readGlobalCap(settings: unknown): number | null {
  return readCap(settings);
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

function formatValue(value: number | null): string {
  return value === null ? "unset" : String(value);
}

function formatProviderStatus(provider: ProviderStatus): string {
  if (provider === null) return "unset";
  if (provider === "mixed") return "mixed";
  return `${provider.value} (${provider.count} models)`;
}

export function formatServerStatus(server: ServerWindow): string {
  if (server.value !== null) return `server ${server.value} (${server.source})`;
  if (server.reason) return `server unavailable (${server.reason})`;
  return "server unset";
}

function formatEffectiveStatus(input: FullStatusInput): string {
  if (input.source === "server") {
    return `effective ${input.effective} (server clamp, client ${input.clientSource} ${input.clientWindow}) of ${input.native} native`;
  }
  return `effective ${input.effective} (${input.source}) of ${input.native} native`;
}

export function formatFullStatus(input: FullStatusInput): string[] {
  return [
    `session ${formatValue(input.session)}`,
    `model ${formatValue(input.model)}`,
    `provider ${formatProviderStatus(input.provider)}`,
    `global ${formatValue(input.global)}`,
    formatServerStatus(input.server),
    formatEffectiveStatus(input),
  ];
}

export function formatScopeStatus(scope: Exclude<StatusScope, "all">, value: number | ProviderStatus | null): string {
  if (scope === "provider") return `provider ${formatProviderStatus(value as ProviderStatus)}`;
  return `${scope} ${formatValue(value as number | null)}`;
}


export const SERVER_PROBE_TIMEOUT_MS = 3000;
export const SERVER_VALUE_TTL_MS = 6 * 60 * 60 * 1000;
export const SERVER_FAILURE_TTL_MS = 60 * 60 * 1000;

export interface ProbeModel {
  provider: string;
  id: string;
  api?: string;
  baseUrl?: string;
}

export interface ProbeContext {
  modelRegistry?: { getApiKey?: (model: unknown) => Promise<string | undefined> | string | undefined };
}

export type ServerFetch = (input: string | URL | Request, init?: RequestInit) => Promise<Response>;

interface ServerCacheEntry extends ServerWindow {
  expiresAt: number;
}

interface ServerCacheFile {
  entries: Record<string, ServerCacheEntry>;
}

interface StoreCache {
  path: string;
  mtimeMs: number;
  providers: Json | null;
}

const serverMemoryCache = new Map<string, ServerCacheEntry>();
const serverInFlight = new Map<string, Promise<ServerWindow>>();
let serverDiskCachePath: string | null = null;
let storeCache: StoreCache | null = null;
let serverFetchOverride: ServerFetch | undefined;

export function setServerFetchForTests(fetchImpl?: ServerFetch): void {
  serverFetchOverride = fetchImpl;
}

export function serverKey(provider: string, modelId: string): string {
  return `${provider}\u0000${modelId}`;
}

export function modelsStorePath(agentDir: string): string {
  return join(agentDir, "models-store.json");
}

export function serverCachePath(agentDir: string): string {
  return join(agentDir, "state", "context-server-window.json");
}

function isPositiveNumber(value: unknown): value is number {
  return typeof value === "number" && Number.isFinite(value) && value > 0;
}

function normalizeBaseUrl(baseUrl: string): string {
  return baseUrl.replace(/\/+$/, "");
}

function endpointUrl(baseUrl: string, path: string): string {
  return `${normalizeBaseUrl(baseUrl)}${path.startsWith("/") ? path : `/${path}`}`;
}

function dataArray(body: unknown): unknown[] {
  if (Array.isArray(body)) return body;
  const object = asObject(body);
  if (!object) return [];
  const data = object.data;
  return Array.isArray(data) ? data : [];
}

function modelIdsMatch(candidate: unknown, modelId: string): boolean {
  if (typeof candidate !== "string") return false;
  if (candidate === modelId) return true;
  // Tolerate provider-prefixed or route-prefixed forms carrying the same tail.
  return candidate.endsWith(`/${modelId}`) || candidate.endsWith(`:${modelId}`);
}

function contextFromLimit(entry: Json): number | null {
  const limit = asObject(entry.limit);
  if (!limit) return null;
  return isPositiveNumber(limit.context) ? limit.context : null;
}

function maxInputTokens(entry: Json): number | null {
  const modelInfo = asObject(entry.model_info);
  if (!modelInfo) return null;
  const value = modelInfo.max_input_tokens ?? modelInfo.maxInputTokens;
  return isPositiveNumber(value) ? value : null;
}

export function parseServerContextFromModels(body: unknown, modelId: string): number | null {
  let best: number | null = null;
  for (const item of dataArray(body)) {
    const entry = asObject(item);
    if (!entry) continue;
    const id = entry.id ?? entry.model ?? entry.name ?? entry.model_name;
    if (!modelIdsMatch(id, modelId)) continue;
    const limitContext = contextFromLimit(entry);
    if (limitContext !== null) return limitContext;
    // Accepted from direct /models response only if present.
    const maxInput = maxInputTokens(entry);
    if (maxInput !== null && (best === null || maxInput < best)) best = maxInput;
  }
  return best;
}

export function parseServerContextFromModelInfo(body: unknown, modelId: string): number | null {
  let best: number | null = null;
  for (const item of dataArray(body)) {
    const entry = asObject(item);
    if (!entry) continue;
    const candidates = [entry.model_name, entry.model, entry.id, entry.route];
    const litellmParams = asObject(entry.litellm_params);
    if (litellmParams) candidates.push(litellmParams.model);
    if (!candidates.some((candidate) => modelIdsMatch(candidate, modelId))) continue;
    const maxInput = maxInputTokens(entry);
    if (maxInput !== null && (best === null || maxInput < best)) best = maxInput;
  }
  return best;
}

export function readServerWindowFromStore(
  storePath: string,
  provider: string,
  modelId: string,
  now = Date.now(),
): ServerWindow {
  void now;
  let mtimeMs = -1;
  try {
    mtimeMs = statSync(storePath).mtimeMs;
  } catch {
    storeCache = null;
    return { value: null, source: "unset", reason: "models-store unavailable" };
  }
  if (!storeCache || storeCache.path !== storePath || storeCache.mtimeMs !== mtimeMs) {
    try {
      const parsed = JSON.parse(readFileSync(storePath, "utf8")) as unknown;
      storeCache = { path: storePath, mtimeMs, providers: asObject(asObject(parsed)?.providers) };
    } catch {
      storeCache = { path: storePath, mtimeMs, providers: null };
      return { value: null, source: "unset", reason: "models-store unreadable" };
    }
  }
  const providers = storeCache.providers;
  if (!providers) return { value: null, source: "unset", reason: "models-store unreadable" };
  const section = asObject(providers[provider]);
  const models = section?.models;
  if (!Array.isArray(models)) return { value: null, source: "unset", reason: "no store match" };
  for (const item of models) {
    const entry = asObject(item);
    if (!entry) continue;
    if (entry.id !== modelId) continue;
    if (isPositiveNumber(entry.contextWindow)) return { value: entry.contextWindow, source: "store" };
    return { value: null, source: "unset", reason: "no store match" };
  }
  return { value: null, source: "unset", reason: "no store match" };
}

function ensureServerDiskCacheLoaded(statePath: string): void {
  if (serverDiskCachePath === statePath) return;
  serverMemoryCache.clear();
  serverDiskCachePath = statePath;
  try {
    const parsed = JSON.parse(readFileSync(statePath, "utf8")) as unknown;
    const entries = asObject(asObject(parsed)?.entries);
    if (!entries) return;
    const now = Date.now();
    for (const [key, raw] of Object.entries(entries)) {
      const entry = asObject(raw);
      if (!entry) continue;
      const expiresAt = typeof entry.expiresAt === "number" ? entry.expiresAt : 0;
      if (expiresAt <= now) continue;
      const value = isPositiveNumber(entry.value) ? entry.value : null;
      const source = entry.source === "live" || entry.source === "store" ? entry.source : "unset";
      if (value === null && source !== "unset") continue;
      const reason = typeof entry.reason === "string" ? entry.reason : undefined;
      serverMemoryCache.set(key, { value, source, reason, expiresAt });
    }
  } catch {
    // Missing or unreadable cache is not fatal.
  }
}

function persistServerCache(statePath: string): void {
  const entries: Record<string, ServerCacheEntry> = {};
  for (const [key, entry] of serverMemoryCache) entries[key] = entry;
  const body = serialize({ entries });
  try {
    mkdirSync(dirname(statePath), { recursive: true });
    const temporary = join(dirname(statePath), `.${basename(statePath)}.${process.pid}.tmp`);
    writeFileSync(temporary, body, "utf8");
    renameSync(temporary, statePath);
  } catch {
    // Persisting the server cache is best-effort.
  }
}

function putServerCache(statePath: string, key: string, window: ServerWindow): void {
  const ttl = window.value !== null ? SERVER_VALUE_TTL_MS : SERVER_FAILURE_TTL_MS;
  serverMemoryCache.set(key, { ...window, expiresAt: Date.now() + ttl });
  persistServerCache(statePath);
}

export function getCachedServerWindow(agentDir: string, provider: string, modelId: string): ServerWindow | null {
  const statePath = serverCachePath(agentDir);
  ensureServerDiskCacheLoaded(statePath);
  const key = serverKey(provider, modelId);
  const entry = serverMemoryCache.get(key);
  if (!entry) return null;
  if (entry.expiresAt <= Date.now()) {
    serverMemoryCache.delete(key);
    return null;
  }
  return { value: entry.value, source: entry.source, reason: entry.reason };
}

async function fetchJson(
  url: string,
  init: RequestInit,
  fetchImpl: ServerFetch,
  timeoutMs: number,
): Promise<unknown> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const response = await fetchImpl(url, { ...init, signal: controller.signal });
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    return (await response.json()) as unknown;
  } finally {
    clearTimeout(timer);
  }
}

async function resolveApiKey(model: ProbeModel, ctx: ProbeContext | undefined): Promise<string | undefined> {
  try {
    const key = await ctx?.modelRegistry?.getApiKey?.(model);
    return typeof key === "string" && key.length > 0 ? key : undefined;
  } catch {
    return undefined;
  }
}

export async function probeServerContext(
  model: ProbeModel,
  options: { fetch?: ServerFetch; ctx?: ProbeContext; timeoutMs?: number } = {},
): Promise<ServerWindow> {
  const fetchImpl = options.fetch ?? globalThis.fetch;
  if (typeof fetchImpl !== "function") {
    return { value: null, source: "unset", reason: "fetch unavailable" };
  }
  if (model.api !== "openai-completions") {
    return { value: null, source: "unset", reason: `unsupported api ${model.api ?? "unknown"}` };
  }
  const baseUrl = typeof model.baseUrl === "string" ? model.baseUrl : "";
  if (baseUrl.length === 0) {
    return { value: null, source: "unset", reason: "missing baseUrl" };
  }
  const timeoutMs = options.timeoutMs ?? SERVER_PROBE_TIMEOUT_MS;
  const apiKey = await resolveApiKey(model, options.ctx);
  const headers: Record<string, string> = {};
  if (apiKey) headers.authorization = `Bearer ${apiKey}`;
  const init: RequestInit = { method: "GET", headers };

  try {
    const modelsBody = await fetchJson(endpointUrl(baseUrl, "/models"), init, fetchImpl, timeoutMs);
    const fromModels = parseServerContextFromModels(modelsBody, model.id);
    if (fromModels !== null) return { value: fromModels, source: "live" };

    try {
      const infoBody = await fetchJson(endpointUrl(baseUrl, "/model/info"), init, fetchImpl, timeoutMs);
      const fromInfo = parseServerContextFromModelInfo(infoBody, model.id);
      if (fromInfo !== null) return { value: fromInfo, source: "live" };
    } catch {
      // /model/info is optional; absence leaves the /models result as authoritative miss.
    }
    return { value: null, source: "unset", reason: "no server match" };
  } catch (cause) {
    const reason = cause instanceof Error ? cause.message : String(cause);
    return { value: null, source: "unset", reason: reason || "probe failed" };
  }
}

export function resolveServerWindowSync(agentDir: string, provider: string, modelId: string): ServerWindow {
  const cached = getCachedServerWindow(agentDir, provider, modelId);
  if (cached) return cached;
  const store = readServerWindowFromStore(modelsStorePath(agentDir), provider, modelId);
  putServerCache(serverCachePath(agentDir), serverKey(provider, modelId), store);
  return store;
}

export function currentServerWindow(agentDir: string, model: ActiveModel | RuntimeModel | null | undefined): ServerWindow {
  if (!model) return { value: null, source: "unset", reason: "no active model" };
  return resolveServerWindowSync(agentDir, model.provider, model.id);
}

export async function refreshServerWindow(
  agentDir: string,
  model: ProbeModel,
  options: { fetch?: ServerFetch; ctx?: ProbeContext; timeoutMs?: number } = {},
): Promise<ServerWindow> {
  const key = serverKey(model.provider, model.id);
  const existing = serverInFlight.get(key);
  if (existing) return existing;
  const statePath = serverCachePath(agentDir);
  ensureServerDiskCacheLoaded(statePath);
  const promise = (async () => {
    const probed = await probeServerContext(model, { ...options, fetch: options.fetch ?? serverFetchOverride });
    if (probed.value !== null) {
      putServerCache(statePath, key, probed);
      return probed;
    }
    // A live miss/failure falls back to the store when it can answer; otherwise
    // keep the probe's unavailable reason. The store is authoritative enough to
    // clamp, but it is not a "live" source.
    const store = readServerWindowFromStore(modelsStorePath(agentDir), model.provider, model.id);
    if (store.value !== null) {
      putServerCache(statePath, key, store);
      return store;
    }
    const reason = probed.reason ?? store.reason ?? "probe failed";
    const result: ServerWindow = { value: null, source: "unset", reason };
    putServerCache(statePath, key, result);
    return result;
  })().finally(() => {
    serverInFlight.delete(key);
  });
  serverInFlight.set(key, promise);
  return promise;
}

// Test-only reset for module-level server caches.
export function resetServerState(): void {
  serverMemoryCache.clear();
  serverInFlight.clear();
  serverDiskCachePath = null;
  storeCache = null;
  serverFetchOverride = undefined;
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

export function agentPaths(): FilePaths {
  const dir = resolveAgentDir();
  return { settings: join(dir, "settings.json"), models: join(dir, "models.json") };
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
  try {
    // WHY: the link count is read inside the try so a stat failure (EACCES, ELOOP,
    // EIO) returns the refused outcome like every other filesystem error here;
    // throwIfNoEntry keeps a vanished file on the rename path, which creates it.
    const links = statSync(resolved, { throwIfNoEntry: false })?.nlink ?? 1;
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

export function modelWindow(models: Json | null, provider: string, modelId: string): number | null {
  const override = asObject(asObject(asObject(asObject(models?.providers)?.[provider])?.modelOverrides)?.[modelId]);
  const value = override?.contextWindow;
  return typeof value === "number" && Number.isFinite(value) && value > 0 ? value : null;
}

// Effective window for one model, with the cap from the write mirror when a
// global write happened, and from `settings` otherwise. The server limit clamps
// the client-resolved window when known.
export function effectiveWindow(model: ActiveModel, input: WindowInput): ResolvedWindow {
  return resolveWindow({
    baseline: input.baseline,
    session: input.session,
    explicit: modelWindow(input.models, model.provider, model.id),
    cap: resolveCap(input.settings),
    server: input.server ?? null,
  });
}

export function syncModelWindow(
  model: RuntimeModel,
  baseline: number,
  session: number | null,
  models: Json | null,
  settings: unknown,
  ui?: StatusUi,
  server?: number | null,
): { changed: boolean; window: number; source: Source; clientWindow: number; clientSource: Exclude<Source, "server"> } {
  const result = effectiveWindow(model, { baseline, session, models, settings, server: server ?? null });
  const changed = model.contextWindow !== result.window;
  if (changed) model.contextWindow = result.window;
  // The in-place mutation is deliberate: pi's own usage and compaction math
  // reads model.contextWindow. The status nudge repaints the model indicator;
  // a footer that caches on the transcript leaf still needs the re-selection
  // applyCap performs.
  if (changed && ui) nudgeStatus(ui);
  return {
    changed,
    window: result.window,
    source: result.source,
    clientWindow: result.clientWindow,
    clientSource: result.clientSource,
  };
}

// A status set and cleared again: writing one is what makes pi repaint, and the
// value itself is never meant to show.
function nudgeStatus(ui: StatusUi): void {
  ui.setStatus("context-window", "");
  ui.setStatus("context-window", undefined);
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

export function providerWindow(
  catalog: ModelCatalog,
  provider: string,
  models: Json | null,
): ProviderStatus {
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

// Set for the span of this file's own re-selection. pi suppresses the
// model_select of a re-selection today, because modelsAreEqual compares type,
// id, and provider only (agent-session.js:1868-1870), so this guard is what
// keeps a pi that stops suppressing it from looping through applyCap again.
let refreshing = false;

// Effective window pi is supposed to hold. A provider registration inside pi can
// assign a pristine registry model to agent.state.model with no event
// (_refreshCurrentModelFromRegistry, agent-session.js:2607, called from the register
// handlers at :2726-2742), which discards the clone this file selected; the watchdog
// compares against this value to notice and re-apply.
let lastWindow: number | null = null;
let watchdog: ReturnType<typeof setInterval> | null = null;
export const WATCHDOG_INTERVAL_MS = 1000;

// One no-auth warning per session: the window stays correct while the provider
// has no auth, but the footer keeps the old one, and repeating that on every
// selection is noise.
let warnedNoAuth = false;

// Re-select the active model so pi appends a model_change entry. That entry is
// what invalidates the pi-powerline-footer context-usage cache, which keys on
// (sessionManager, leafId), so the footer recomputes the window on its next
// render.
export async function refreshActiveModel(
  pi: ModelSelector,
  model: RuntimeModel,
  window: number,
  baseline: number,
): Promise<boolean> {
  const clone: RuntimeModel = { ...model, contextWindow: window };
  // WHY: nativeCache is keyed by object identity and pi holds the clone from here
  // on, so the clone needs the native baseline under its own identity. Without the
  // re-key the next applyCap would take the capped window as the native baseline,
  // and a later clear would restore the cap instead of the native window.
  nativeCache.set(clone, baseline);
  refreshing = true;
  try {
    return await pi.setModel(clone);
  } finally {
    refreshing = false;
  }
}

// Physical model whose window the footer would show, but only while that window
// still disagrees with the effective one: a routed selection is the only case
// where the two can differ.
export function routedPhysicalModel(source: RoutedSource, effective: number): RuntimeModel | null {
  const usage = source.getContextUsage();
  if (usage === undefined || usage.contextWindow === effective) return null;
  const entries = source.sessionManager.getEntries();
  for (let index = entries.length - 1; index >= 0; index -= 1) {
    const entry = asObject(entries[index]);
    if (entry?.type !== "message") continue;
    const message = asObject(entry.message);
    if (message?.role !== "assistant") continue;
    const provider = message.provider;
    const id = message.responseModel ?? message.model;
    if (typeof provider !== "string" || typeof id !== "string") return null;
    return source.modelRegistry.find(provider, id) ?? null;
  }
  return null;
}

// Original window of every registry object this file wrote, so a restore can put
// each one back.
const routedOriginals = new Map<RuntimeModel, number>();

// A routed selection reads routedModel.model, the registry's physical object
// (agent-session.js:1020-1027), and ModelRegistry.find hands back that same
// object (model-registry.js:24-26 -> model-runtime.js:287-289), so writing the
// window there is what the footer reports. Risk: the registry object is
// process-wide, so every other session in this process sees the mutated window
// until it is restored. Recording the original once and restoring it is what
// keeps a later direct selection of this physical model from inheriting the
// virtual cap.
export function syncRoutedWindow(source: RoutedSource, effective: number): RuntimeModel | null {
  // Restore first: the target may be the object this file already capped, and
  // the detection below has to compare its native window with the effective one
  // rather than the capped window a previous sync left on it.
  restoreRoutedWindows();
  const target = routedPhysicalModel(source, effective);
  if (target === null) return null;
  routedOriginals.set(target, target.contextWindow);
  target.contextWindow = effective;
  return target;
}

export function restoreRoutedWindows(): void {
  for (const [model, original] of routedOriginals) model.contextWindow = original;
  routedOriginals.clear();
}

// One re-apply path for a selection, a status command, and a watchdog tick: a
// tick has to do exactly what a selection does, so the body lives here and takes
// the handle and the agent paths it needs instead of closing over them.
export async function applyCap(
  pi: CapHost,
  paths: FilePaths,
  model: RuntimeModel,
  ui?: CapUi,
  routed?: RoutedSource,
): Promise<void> {
  // Restore before reading the baseline: a routed physical model can be the
  // very object selected here, and its capped window would otherwise become
  // the native baseline that a later clear can never undo.
  restoreRoutedWindows();
  const cached = nativeCache.get(model);
  const baseline = cached ?? model.contextWindow;
  if (cached === undefined) nativeCache.set(model, baseline);
  const agentDir = dirname(paths.settings);
  const server = currentServerWindow(agentDir, model);
  const result = syncModelWindow(
    model,
    baseline,
    sessionOverride,
    readJson(paths.models),
    pi.getSettings(),
    ui,
    server.value,
  );
  // The window pi should hold from here on, set before the early return so the
  // watchdog has a value to compare against when nothing was re-selected.
  lastWindow = result.window;
  // The in-place mutation above is not enough for the footer:
  // pi-powerline-footer caches context usage per (sessionManager, leafId)
  // (context-usage.ts:66-84), so only a new transcript entry makes it
  // recompute. Re-selecting costs one model_change entry and one
  // thinking-level re-apply per effective change, and that is the price of
  // invalidating a leaf-keyed cache; an unchanged window re-selects nothing.
  // A routed selection displays the physical model's window, which the mutation
  // above did not touch, so write it before the re-selection: the leaf move
  // then repaints the footer from the routed window.
  // WHY before the early return: the restore at the top of this function undid
  // the routed window this file applied last time, so an unchanged window still
  // has to be written back for the footer to keep showing it.
  if (routed) syncRoutedWindow(routed, result.window);
  if (!result.changed) return;
  const selected = await refreshActiveModel(pi, model, result.window, baseline);
  // The mutation already repainted through nudgeStatus, and pi's own usage and
  // compaction math reads model.contextWindow, so a refused re-selection costs
  // only the footer refresh.
  if (selected || !ui || warnedNoAuth) return;
  warnedNoAuth = true;
  ui.notify(
    `cannot re-select ${model.provider}/${model.id}: no auth for that provider, so the pi-powerline-footer context window stays stale until the model is selected again`,
    "warning",
  );
}

// One tick of the re-apply watchdog: pi can replace the model this file selected
// without firing an event, so a tick re-applies once the window pi holds no
// longer matches the window this file last applied.
export function watchdogTick(pi: CapHost, source: WatchdogSource): Promise<void> | undefined {
  if (refreshing) return undefined;
  if (lastWindow === null) return undefined;
  const { model } = source;
  if (model === undefined) return undefined;
  if (model.contextWindow === lastWindow) return undefined;
  return applyCap(pi, agentPaths(), model, source.ui, source);
}

// The cost of watching: one number comparison per second, plus one model_change
// entry for each replacement pi performs, which is the only way to invalidate the
// footer's leaf-keyed cache after a replacement that fires no event.
export function startWatchdog(pi: CapHost, source: WatchdogSource): void {
  // Clears a previous timer without going through stopWatchdog: that also forgets
  // the window applyCap just recorded, which is the value every tick compares
  // against, so restarting the timer has to keep it.
  clearWatchdog();
  watchdog = setInterval(() => {
    void watchdogTick(pi, source);
  }, WATCHDOG_INTERVAL_MS);
  // WHY: an unref'd timer cannot keep the process alive once pi has exited.
  watchdog.unref?.();
}

function clearWatchdog(): void {
  if (watchdog !== null) {
    clearInterval(watchdog);
    watchdog = null;
  }
}

export function stopWatchdog(): void {
  clearWatchdog();
  // A tick queued before the stop finds no window to restore and does nothing.
  lastWindow = null;
}

export default function (pi: ExtensionAPI) {
  const paths = agentPaths();

  const probeAndRefresh = (model: RuntimeModel, ctx: RoutedSource & { ui?: CapUi; model?: RuntimeModel }): void => {
    const probeModel = model as ProbeModel;
    void refreshServerWindow(resolveAgentDir(), probeModel, { ctx }).then(() => {
      const current = ctx.model;
      if (!current) return;
      if (current.provider !== probeModel.provider || current.id !== probeModel.id) return;
      return applyCap(pi, paths, current, ctx.ui, ctx);
    });
  };

  // The host repaints after a model switch, but the effective window can change
  // here without changing the model, so nudge explicitly rather than relying on
  // that render. The re-selection this triggers must not come back through here.
  pi.on("model_select", ({ model }, ctx) => {
    if (refreshing) return;
    const applied = applyCap(pi, paths, model, ctx.ui, ctx);
    void applied.then(() => probeAndRefresh(model, ctx));
    return applied;
  });
  pi.on("session_shutdown", () => {
    stopWatchdog();
    restoreRoutedWindows();
  });
  pi.on("session_start", async (event, ctx) => {
    stopWatchdog();
    // Restore first: a registry object left carrying the previous session's
    // window would otherwise hide the routed selection this one makes.
    restoreRoutedWindows();
    // A reload is the one point where pi re-reads settings.json, so its cache is
    // authoritative again and the mirror would only hold a stale copy.
    if (event.reason === "reload") resetWrittenCap();
    warnedNoAuth = false;
    if (!ctx.model) return;
    await applyCap(pi, paths, ctx.model, ctx.ui, ctx);
    // The context itself is the source, not a copy of it: its model is a getter,
    // so every tick reads whatever model pi is holding at that moment.
    if (ctx.model) startWatchdog(pi, ctx);
    if (ctx.model) probeAndRefresh(ctx.model, ctx);
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
        await applyCap(pi, paths, model, ctx.ui, ctx);
      }

      const settings = readJson(paths.settings);
      const models = readJson(paths.models);
      const baseline = nativeCache.get(model) ?? model.contextWindow;
      const server = currentServerWindow(resolveAgentDir(), model);
      const result = resolveWindow({
        baseline,
        session: sessionOverride,
        explicit: modelWindow(models, active.provider, active.id),
        cap: readCap(settings),
        server: server.value,
      });

      if (command.kind === "status" && command.scope !== "all") {
        if (command.scope === "session") {
          ctx.ui.notify(formatScopeStatus("session", sessionOverride), "info");
          return;
        }
        if (command.scope === "global") {
          ctx.ui.notify(formatScopeStatus("global", readCap(settings)), "info");
          return;
        }
        if (command.scope === "model") {
          ctx.ui.notify(
            formatScopeStatus("model", modelWindow(models, command.provider, command.model)),
            "info",
          );
          return;
        }
        ctx.ui.notify(
          formatScopeStatus("provider", providerWindow(ctx.modelRegistry, command.provider, models)),
          "info",
        );
        return;
      }

      const lines = formatFullStatus({
        session: sessionOverride,
        model: modelWindow(models, active.provider, active.id),
        provider: providerWindow(ctx.modelRegistry, active.provider, models),
        global: readCap(settings),
        server,
        effective: result.window,
        source: result.source,
        clientWindow: result.clientWindow,
        clientSource: result.clientSource,
        native: baseline,
      });
      ctx.ui.notify(lines.join("\n"), "info");
    },
  });
}
