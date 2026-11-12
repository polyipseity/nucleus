// pi context-window control in three duties: enforce one global ceiling when a
// model is selected, serve /context-window for status plus set and clear at
// four scopes, and render the footer that reports the effective window. Model
// and provider windows are models.json entries that pi applies itself, so this
// file reads them only to report and writes them only on request. Precedence:
// session > explicit model window > global ceiling > native, so an explicit
// window always wins over the ceiling. Each `as` below narrows a value this
// file already checked with asObject or a string guard.

import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { readFileSync, realpathSync, renameSync, rmSync, statSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { basename, dirname, isAbsolute, join, relative, resolve, sep } from "node:path";

export type Scope = "session" | "model" | "provider" | "global";
export type StatusScope = "all" | Scope;
export type Source = "session" | "model" | "global" | "native";
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
  effective: number;
  source: Source;
  native: number;
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

// Footer types stay structural: the component and the tests both build them, so
// neither needs a pi runtime type. FooterEntry is the part of a session entry
// the footer scans for usage, and FooterEntryUsage the part it sums.
export interface FooterEntryUsage {
  input: number;
  output: number;
  cacheRead: number;
  cacheWrite: number;
  cost: { total: number };
}

export interface FooterEntry {
  type: string;
  usage?: FooterEntryUsage;
  message?: { role?: string; usage?: FooterEntryUsage };
}

export interface FooterSessionManager {
  getEntries(): readonly FooterEntry[];
  getCwd(): string;
  getSessionName(): string | null | undefined;
}

export interface FooterData {
  getGitBranch(): string | null;
  getExtensionStatuses(): ReadonlyMap<string, string>;
  getAvailableProviderCount(): number;
}

export interface FooterModel {
  provider: string;
  id: string;
  reasoning: boolean;
}

export interface FooterSnapshotSource {
  readonly model: FooterModel | undefined;
  readonly thinkingLevel: string | null | undefined;
  readonly sessionManager: FooterSessionManager;
  readonly modelRegistry: { isUsingOAuth(model: FooterModel): boolean };
  getContextUsage(): { tokens: number | null } | undefined;
  readonly footerData: FooterData;
}

export interface FooterUsage {
  input: number;
  output: number;
  cacheRead: number;
  cacheWrite: number;
  cost: number;
}

export interface FooterSnapshot {
  cwd: string;
  home: string;
  branch: string | null;
  sessionName: string | null;
  modelId: string | null;
  provider: string | null;
  providerCount: number;
  reasoning: boolean;
  thinkingLevel: string | null;
  tokens: number | null;
  effectiveWindow: number;
  source: Source;
  usage: FooterUsage;
  latestCacheHitRate: number | undefined;
  subscription: boolean;
  /** Extension statuses, ordered by key; renderFooterLines sanitizes them. */
  statuses: readonly string[];
}

export interface FooterTheme {
  fg(color: string, text: string): string;
  bold(text: string): string;
}

export interface FooterFormatting {
  visibleWidth(text: string): number;
  truncateToWidth(text: string, width: number, ellipsis?: string): string;
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

function formatValue(value: number | null): string {
  return value === null ? "unset" : String(value);
}

function formatProviderStatus(provider: ProviderStatus): string {
  if (provider === null) return "unset";
  if (provider === "mixed") return "mixed";
  return `${provider.value} (${provider.count} models)`;
}

export function formatFullStatus(input: FullStatusInput): string[] {
  return [
    `session ${formatValue(input.session)}`,
    `model ${formatValue(input.model)}`,
    `provider ${formatProviderStatus(input.provider)}`,
    `global ${formatValue(input.global)}`,
    `effective ${input.effective} (${input.source}) of ${input.native} native`,
  ];
}

export function formatScopeStatus(scope: Exclude<StatusScope, "all">, value: number | ProviderStatus | null): string {
  if (scope === "provider") return `provider ${formatProviderStatus(value as ProviderStatus)}`;
  return `${scope} ${formatValue(value as number | null)}`;
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

export function syncModelWindow(
  model: RuntimeModel,
  baseline: number,
  session: number | null,
  models: Json | null,
  settings: unknown,
  ui?: StatusUi,
): { changed: boolean; window: number; source: Source } {
  const result = effectiveWindow(model, { baseline, session, models, settings });
  const changed = model.contextWindow !== result.window;
  if (changed) model.contextWindow = result.window;
  // The in-place mutation is deliberate: modelsAreEqual compares type, id, and
  // provider only, so replacing the model with the same one emits no
  // model_select, while pi's own usage and compaction math reads
  // model.contextWindow. The status nudge is what repaints the footer and the
  // model indicator so the new window shows immediately.
  if (changed && ui) nudgeStatus(ui);
  return { changed, window: result.window, source: result.source };
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

// The built-in footer caches its stats while (session, sessionId, leafId,
// entryCount, limitsModel) is unchanged and renders the context window out of
// that cached object (modes/interactive/components/footer.js:82-95, :134), so an
// in-place model.contextWindow mutation never repaints the denominator. This
// footer recomputes on every render and prints the window this file applied, so
// a routed or virtual selection is reported without touching registry objects.
// Fidelity gaps against the native footer: no "(auto)" compaction marker, no
// experimental "xp" marker, no "→ routed" arrow, and no session.routedModel.

// Same buckets the native footer prints: 999, 1.5k, 35k, 1.5M, 35M.
export function formatTokens(count: number): string {
  if (count < 1000) return count.toString();
  if (count < 10000) return `${(count / 1000).toFixed(1)}k`;
  if (count < 1000000) return `${Math.round(count / 1000)}k`;
  if (count < 10000000) return `${(count / 1000000).toFixed(1)}M`;
  return `${Math.round(count / 1000000)}M`;
}

// Native formatCwdForFooter: only a cwd inside home is shortened, and an exact
// match becomes "~" rather than "~/.".
export function footerCwd(cwd: string, home: string): string {
  if (!home) return cwd;
  const resolvedCwd = resolve(cwd);
  const resolvedHome = resolve(home);
  const relativeToHome = relative(resolvedHome, resolvedCwd);
  const insideHome =
    relativeToHome === "" ||
    (relativeToHome !== ".." && !relativeToHome.startsWith(`..${sep}`) && !isAbsolute(relativeToHome));
  if (!insideHome) return cwd;
  return relativeToHome === "" ? "~" : `~${sep}${relativeToHome}`;
}

const ESCAPE = 0x1b;
const RESET = "\x1b[0m";

// Length of the ANSI sequence starting at `index`, or 0 when there is none. CSI
// and OSC cover what pi's theme emits; other escapes are two bytes.
function escapeLength(text: string, index: number): number {
  if (text.charCodeAt(index) !== ESCAPE) return 0;
  const introducer = text[index + 1];
  if (introducer === "[") {
    for (let cursor = index + 2; cursor < text.length; cursor += 1) {
      const code = text.charCodeAt(cursor);
      if (code >= 0x40 && code <= 0x7e) return cursor - index + 1;
    }
    return 0;
  }
  if (introducer === "]") {
    for (let cursor = index + 2; cursor < text.length; cursor += 1) {
      const code = text.charCodeAt(cursor);
      if (code === 0x07) return cursor - index + 1;
      if (code === ESCAPE && text[cursor + 1] === "\\") return cursor - index + 2;
    }
    return 0;
  }
  return introducer === undefined ? 0 : 2;
}

// Cells one code point occupies. Control characters and combining marks take
// none, the East Asian wide blocks and emoji take two, everything else one, so
// a combining sequence can measure narrower than the terminal draws it.
function cellWidth(codePoint: number): number {
  if (codePoint < 0x20 || (codePoint >= 0x7f && codePoint < 0xa0)) return 0;
  if (
    (codePoint >= 0x0300 && codePoint <= 0x036f) ||
    (codePoint >= 0x1ab0 && codePoint <= 0x1aff) ||
    (codePoint >= 0x1dc0 && codePoint <= 0x1dff) ||
    (codePoint >= 0x200b && codePoint <= 0x200f) ||
    (codePoint >= 0x20d0 && codePoint <= 0x20ff) ||
    (codePoint >= 0xfe00 && codePoint <= 0xfe0f) ||
    (codePoint >= 0xfe20 && codePoint <= 0xfe2f) ||
    codePoint === 0xfeff
  ) {
    return 0;
  }
  if (
    (codePoint >= 0x1100 && codePoint <= 0x115f) ||
    (codePoint >= 0x2e80 && codePoint <= 0x303e) ||
    (codePoint >= 0x3041 && codePoint <= 0x33ff) ||
    (codePoint >= 0x3400 && codePoint <= 0x4dbf) ||
    (codePoint >= 0x4e00 && codePoint <= 0x9fff) ||
    (codePoint >= 0xa000 && codePoint <= 0xa4cf) ||
    (codePoint >= 0xac00 && codePoint <= 0xd7a3) ||
    (codePoint >= 0xf900 && codePoint <= 0xfaff) ||
    (codePoint >= 0xfe30 && codePoint <= 0xfe6f) ||
    (codePoint >= 0xff00 && codePoint <= 0xff60) ||
    (codePoint >= 0xffe0 && codePoint <= 0xffe6) ||
    (codePoint >= 0x1f300 && codePoint <= 0x1f64f) ||
    (codePoint >= 0x1f900 && codePoint <= 0x1f9ff) ||
    (codePoint >= 0x20000 && codePoint <= 0x3fffd)
  ) {
    return 2;
  }
  return 1;
}

// WHY local: the test suite imports this module with no runtime dependencies, so
// @earendil-works/pi-tui cannot be loaded here.
function visibleWidth(text: string): number {
  let width = 0;
  for (let index = 0; index < text.length; ) {
    const escape = escapeLength(text, index);
    if (escape > 0) {
      index += escape;
      continue;
    }
    const codePoint = text.codePointAt(index) ?? 0;
    // Native visibleWidth renders a tab as three spaces.
    width += codePoint === 0x09 ? 3 : cellWidth(codePoint);
    index += codePoint > 0xffff ? 2 : 1;
  }
  return width;
}

interface WidthSlice {
  text: string;
  styled: boolean;
}

// Leading slice of `text` that fits in `limit` cells, keeping the escape
// sequences it walked past so the slice stays styled.
function takeWidth(text: string, limit: number): WidthSlice {
  let taken = "";
  let width = 0;
  let styled = false;
  for (let index = 0; index < text.length; ) {
    const escape = escapeLength(text, index);
    if (escape > 0) {
      taken += text.slice(index, index + escape);
      styled = true;
      index += escape;
      continue;
    }
    const codePoint = text.codePointAt(index) ?? 0;
    const cells = codePoint === 0x09 ? 3 : cellWidth(codePoint);
    if (width + cells > limit) break;
    const size = codePoint > 0xffff ? 2 : 1;
    taken += text.slice(index, index + size);
    width += cells;
    index += size;
  }
  return { text: taken, styled };
}

// Native truncation keeps styles open through the ellipsis and always resets;
// this resets only when the slice carries an escape, so plain text stays plain.
function truncateToWidth(text: string, width: number, ellipsis = "..."): string {
  if (width <= 0) return "";
  if (visibleWidth(text) <= width) return text;
  const ellipsisWidth = visibleWidth(ellipsis);
  if (ellipsisWidth >= width) return takeWidth(ellipsis, width).text;
  const head = takeWidth(text, width - ellipsisWidth);
  return `${head.text}${head.styled ? RESET : ""}${ellipsis}`;
}

export const footerFormatting: FooterFormatting = { visibleWidth, truncateToWidth };

// Native footer sanitizing: one line, no tabs, collapsed spaces.
function sanitizeStatus(text: string): string {
  return text.replace(/[\r\n\t]/g, " ").replace(/ +/g, " ").trim();
}

export function renderFooterLines(
  snapshot: FooterSnapshot,
  width: number,
  theme: FooterTheme,
  fmt: FooterFormatting = footerFormatting,
): string[] {
  let pwd = footerCwd(snapshot.cwd, snapshot.home);
  if (snapshot.branch) pwd = `${pwd} (${snapshot.branch})`;
  if (snapshot.sessionName) pwd = `${pwd} • ${snapshot.sessionName}`;
  const pwdLine = fmt.truncateToWidth(theme.fg("dim", pwd), width, theme.fg("dim", "..."));

  const { usage } = snapshot;
  const statsParts: string[] = [];
  if (usage.input) statsParts.push(`↑${formatTokens(usage.input)}`);
  if (usage.output) statsParts.push(`↓${formatTokens(usage.output)}`);
  if (usage.cacheRead) statsParts.push(`R${formatTokens(usage.cacheRead)}`);
  if (usage.cacheWrite) statsParts.push(`W${formatTokens(usage.cacheWrite)}`);
  if ((usage.cacheRead > 0 || usage.cacheWrite > 0) && snapshot.latestCacheHitRate !== undefined) {
    statsParts.push(`CH${snapshot.latestCacheHitRate.toFixed(1)}%`);
  }
  // Native prints the cost when either the cost or the subscription applies.
  if (usage.cost || snapshot.subscription) {
    statsParts.push(`$${usage.cost.toFixed(3)}${snapshot.subscription ? " (sub)" : ""}`);
  }

  const percent =
    snapshot.tokens === null
      ? null
      : snapshot.effectiveWindow > 0
        ? (snapshot.tokens / snapshot.effectiveWindow) * 100
        : 0;
  const windowText = formatTokens(snapshot.effectiveWindow);
  const sourceNote = snapshot.source === "native" ? "" : ` (${snapshot.source})`;
  const contextText = percent === null ? `?/${windowText}${sourceNote}` : `${percent.toFixed(1)}%/${windowText}${sourceNote}`;
  statsParts.push(
    percent !== null && percent > 90
      ? theme.fg("error", contextText)
      : percent !== null && percent > 70
        ? theme.fg("warning", contextText)
        : contextText,
  );

  // Native order (modes/interactive/components/footer.js): the stats side is
  // truncated to the full width first (:196-201), the model side then gets only
  // what is left past the two-space gap (:203), and with no budget left the line
  // falls back to the stats alone (:210-213).
  let statsLeft = statsParts.join(" ");
  let statsLeftWidth = fmt.visibleWidth(statsLeft);
  if (statsLeftWidth > width) {
    statsLeft = fmt.truncateToWidth(statsLeft, width, "...");
    statsLeftWidth = fmt.visibleWidth(statsLeft);
  }

  const modelName = snapshot.modelId ?? "no-model";
  let rightSide = modelName;
  if (snapshot.reasoning) {
    const level = snapshot.thinkingLevel ?? "off";
    rightSide = level === "off" ? `${modelName} • thinking off` : `${modelName} • ${level}`;
  }

  // Native keeps two spaces between the stats and the model and drops the
  // provider prefix rather than truncating for it.
  const minPadding = 2;
  if (snapshot.providerCount > 1 && snapshot.modelId !== null && snapshot.provider !== null) {
    const withProvider = `(${snapshot.provider}) ${rightSide}`;
    if (statsLeftWidth + minPadding + fmt.visibleWidth(withProvider) <= width) rightSide = withProvider;
  }

  const rightSideWidth = fmt.visibleWidth(rightSide);
  let statsLine: string;
  if (statsLeftWidth + minPadding + rightSideWidth <= width) {
    const padding = " ".repeat(width - statsLeftWidth - rightSideWidth);
    statsLine = statsLeft + padding + rightSide;
  } else {
    const availableForRight = width - statsLeftWidth - minPadding;
    if (availableForRight > 0) {
      const truncatedRight = fmt.truncateToWidth(rightSide, availableForRight, "");
      const padding = " ".repeat(Math.max(0, width - statsLeftWidth - fmt.visibleWidth(truncatedRight)));
      statsLine = statsLeft + padding + truncatedRight;
    } else {
      statsLine = statsLeft;
    }
  }

  // Dim the parts around any colored context segment separately, as the native
  // footer does: the segment's own reset would clear an outer dim.
  const lines = [pwdLine, theme.fg("dim", statsLeft) + theme.fg("dim", statsLine.slice(statsLeft.length))];

  if (snapshot.statuses.length > 0) {
    const statusLine = snapshot.statuses.map(sanitizeStatus).join(" ");
    lines.push(fmt.truncateToWidth(statusLine, width, theme.fg("dim", "...")));
  }
  return lines;
}

// Native footer arithmetic (core/usage-totals.js): sum the usage of usage
// entries, assistant and toolResult messages, and compaction or branch summaries.
function addUsage(totals: FooterUsage, usage: FooterEntryUsage): void {
  totals.input += usage.input;
  totals.output += usage.output;
  totals.cacheRead += usage.cacheRead;
  totals.cacheWrite += usage.cacheWrite;
  totals.cost += usage.cost.total;
}

// HOME first, then USERPROFILE, exactly as the native footer picks the home it
// shortens against.
function footerHome(): string {
  return process.env.HOME || process.env.USERPROFILE || "";
}

export function buildFooterSnapshot(
  source: FooterSnapshotSource,
  effective: { window: number; source: Source },
): FooterSnapshot {
  const usage: FooterUsage = { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, cost: 0 };
  let latestCacheHitRate: number | undefined;
  for (const entry of source.sessionManager.getEntries()) {
    if (entry.type === "usage" && entry.usage) {
      addUsage(usage, entry.usage);
    } else if (entry.type === "message" && entry.message?.role === "assistant" && entry.message.usage) {
      const messageUsage = entry.message.usage;
      addUsage(usage, messageUsage);
      const promptTokens = messageUsage.input + messageUsage.cacheRead + messageUsage.cacheWrite;
      latestCacheHitRate = promptTokens > 0 ? (messageUsage.cacheRead / promptTokens) * 100 : undefined;
    } else if (entry.type === "message" && entry.message?.role === "toolResult" && entry.message.usage) {
      addUsage(usage, entry.message.usage);
    } else if ((entry.type === "branch_summary" || entry.type === "compaction") && entry.usage) {
      addUsage(usage, entry.usage);
    }
  }

  const model = source.model;
  const contextUsage = source.getContextUsage();
  return {
    cwd: source.sessionManager.getCwd(),
    home: footerHome(),
    branch: source.footerData.getGitBranch(),
    sessionName: source.sessionManager.getSessionName() ?? null,
    modelId: model?.id ?? null,
    provider: model?.provider ?? null,
    providerCount: source.footerData.getAvailableProviderCount(),
    reasoning: model?.reasoning ?? false,
    thinkingLevel: source.thinkingLevel ?? null,
    tokens: contextUsage?.tokens ?? null,
    effectiveWindow: effective.window,
    source: effective.source,
    usage,
    latestCacheHitRate,
    subscription: model ? source.modelRegistry.isUsingOAuth(model) : false,
    statuses: [...source.footerData.getExtensionStatuses().entries()]
      // Code-unit order, not locale collation, so the status line is identical
      // in every locale.
      .sort(([first], [second]) => (first < second ? -1 : first > second ? 1 : 0))
      .map(([, text]) => text),
  };
}

// Window a model carries on first sight, before any cap this file applied.
const nativeCache = new WeakMap<object, number>();
let sessionOverride: number | null = null;

// Effective window this file last applied, read by the footer on every render.
let lastEffective: { window: number; source: Source } | null = null;

export default function (pi: ExtensionAPI) {
  const settingsPath = join(agentDir(), "settings.json");
  const modelsPath = join(agentDir(), "models.json");
  const paths: FilePaths = { settings: settingsPath, models: modelsPath };

  const applyCap = (
    model: { provider: string; id: string; contextWindow: number },
    ui?: StatusUi,
  ): void => {
    const cached = nativeCache.get(model);
    const baseline = cached ?? model.contextWindow;
    if (cached === undefined) nativeCache.set(model, baseline);
    const previous = lastEffective;
    const result = syncModelWindow(model, baseline, sessionOverride, readJson(modelsPath), pi.getSettings(), ui);
    lastEffective = { window: result.window, source: result.source };
    // A repaint is driven by a window change, so a layer switch that keeps the
    // same window (session 200000 over an identical model window, say) would
    // leave the footer showing the previous source label until something else
    // repaints.
    const sourceMoved = previous !== null && (previous.window !== result.window || previous.source !== result.source);
    if (!result.changed && sourceMoved && ui) nudgeStatus(ui);
  };

  // Installed on every session_start on purpose. pi clears extension UI when it
  // invalidates a session (modes/interactive/interactive-mode.js:343), which also
  // replaces the context object this component reads, and setExtensionFooter
  // disposes the previous custom footer before building the new one (:1885-1887).
  const installFooter = (ctx: ExtensionContext): void => {
    ctx.ui.setFooter((tui, theme, footerData) => {
      const unsubscribe = footerData.onBranchChange(() => tui.requestRender());
      return {
        dispose: unsubscribe,
        invalidate() {},
        render(width: number): string[] {
          const effective: { window: number; source: Source } = lastEffective ?? {
            window: ctx.model?.contextWindow ?? 0,
            source: "native",
          };
          const source: FooterSnapshotSource = {
            model: ctx.model,
            thinkingLevel: ctx.thinkingLevel ?? null,
            sessionManager: ctx.sessionManager,
            modelRegistry: ctx.modelRegistry,
            getContextUsage: () => ctx.getContextUsage(),
            footerData,
          };
          return renderFooterLines(buildFooterSnapshot(source, effective), width, theme);
        },
      };
    });
  };

  pi.on("model_select", ({ model }) => applyCap(model));
  pi.on("session_start", (event, ctx) => {
    // A reload is the one point where pi re-reads settings.json, so its cache is
    // authoritative again and the mirror would only hold a stale copy.
    if (event.reason === "reload") resetWrittenCap();
    // Reset before the model check: a model-less start must fall back to the
    // native zero window instead of the previous session's applied value.
    lastEffective = null;
    if (ctx.model) applyCap(ctx.model, ctx.ui);
    if (ctx.mode === "tui") {
      installFooter(ctx);
      // setFooter already repaints; the nudge repaints once more so the very
      // first frame is the custom footer and not the cached built-in one.
      nudgeStatus(ctx.ui);
    }
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
        applyCap(model, ctx.ui);
      }

      const settings = readJson(settingsPath);
      const models = readJson(modelsPath);
      const baseline = nativeCache.get(model) ?? model.contextWindow;
      const result = resolveWindow({
        baseline,
        session: sessionOverride,
        explicit: modelWindow(models, active.provider, active.id),
        cap: readCap(settings),
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
        effective: result.window,
        source: result.source,
        native: baseline,
      });
      ctx.ui.notify(lines.join("\n"), "info");
    },
  });
}
