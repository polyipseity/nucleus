/**
 * Claude Code mod providing prompt tools: /continue, /copy-user-prompt,
 * /repeat-user-prompt.
 *
 * Semantics mirror src/users/default/pi/extensions/prompt-tools.ts:
 * - `sent`/`queued` shortcuts return the newest prompt of that kind.
 * - `queued` prompts are read from
 *   <nucleus user root>/state/harness-bridge/commands/claude/*.json without
 *   consuming them.
 * - `pick` prints a numbered reverse-chronological list of every retained sent
 *   and queued prompt; `pick <index>` selects that 1-based candidate. No dialog
 *   picker API is assumed.
 * - copy goes through the shared harness-clipboard command (stdin) with a
 *   visible fallback when no clipboard command works.
 * - repeat returns the selected prompt as `{ text }` so command.run injects it
 *   as a new user turn.
 * - continue returns `{ text: " " }` to continue/retry the turn when a sent
 *   message exists and the runtime is idle; otherwise it returns a one-line
 *   message and does nothing else.
 * - empty state returns one line and does nothing else.
 */

import { execFile } from "node:child_process";
import { readdirSync, readFileSync, statSync } from "node:fs";
import { homedir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";

const runFile = promisify(execFile);

export const EMPTY_SESSION_MESSAGE = "Nothing to repeat yet \u2014 this session has no user message.";
export const NOTHING_TO_COPY_QUEUED_MESSAGE = "Nothing to copy yet \u2014 no queued prompt.";
export const NOTHING_TO_REPEAT_QUEUED_MESSAGE = "Nothing to repeat yet \u2014 no queued prompt.";
export const NOTHING_TO_CONTINUE_MESSAGE = EMPTY_SESSION_MESSAGE;

export function nucleusUserRoot(
  platform = process.platform,
  env = process.env,
  home = homedir,
) {
  if (platform === "darwin") {
    return path.join(home(), "Library", "Application Support", "nucleus");
  }
  if (platform === "win32") {
    const localAppData = env.LOCALAPPDATA;
    return localAppData
      ? path.join(localAppData, "nucleus")
      : path.join(home(), "AppData", "Local", "nucleus");
  }
  return path.join(home(), ".local", "share", "nucleus");
}

export function claudeQueuedCommandsDir(root) {
  return path.join(root, "state", "harness-bridge", "commands", "claude");
}

function queuedFilePromptText(value) {
  if (!isRecord(value) || typeof value.text !== "string") return null;
  const text = value.text.trim();
  return text === "" ? null : text;
}

/** Read all queued harness-bridge prompts for Claude without consuming them. */
export function readQueuedPromptList(commandsDir) {
  let names;
  try {
    names = readdirSync(commandsDir).filter((name) => name.endsWith(".json"));
  } catch {
    return [];
  }
  const prompts = [];
  for (const name of names) {
    const filePath = path.join(commandsDir, name);
    try {
      const text = queuedFilePromptText(JSON.parse(readFileSync(filePath, "utf8")));
      if (text === null) continue;
      const mtimeMs = statSync(filePath).mtimeMs;
      prompts.push({ text, mtimeMs });
    } catch {
      // unreadable/invalid queued entries are ignored
    }
  }
  return prompts;
}

/** Read the newest queued harness-bridge prompt for Claude without consuming it. */
export function readQueuedPromptFile(commandsDir) {
  let names;
  try {
    names = readdirSync(commandsDir).filter((name) => name.endsWith(".json"));
  } catch {
    return null;
  }
  let newest = "";
  for (const name of names) {
    if (name > newest) newest = name;
  }
  if (newest === "") return null;
  try {
    return queuedFilePromptText(JSON.parse(readFileSync(path.join(commandsDir, newest), "utf8")));
  } catch {
    return null;
  }
}

function isRecord(value) {
  return typeof value === "object" && value !== null;
}

export function extractTextContent(content) {
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) return null;
  const parts = [];
  for (const item of content) {
    if (!isRecord(item)) continue;
    if (typeof item.text === "string") parts.push(item.text);
    else if (item.type === "text" && typeof item.content === "string") parts.push(item.content);
  }
  if (parts.length === 0) return null;
  return parts.join("\n");
}

function messageRole(message) {
  if (!isRecord(message)) return null;
  if (typeof message.role === "string") return message.role;
  const info = message.info;
  if (isRecord(info) && typeof info.role === "string") return info.role;
  return null;
}

function messageContent(message) {
  if (!isRecord(message)) return null;
  if (message.content !== undefined) return message.content;
  if (Array.isArray(message.parts)) return message.parts;
  if (isRecord(message.info) && message.info.content !== undefined) return message.info.content;
  return null;
}

export function extractUserPromptText(message) {
  return extractTextContent(messageContent(message));
}

function messageTimestamp(message) {
  if (!isRecord(message)) return undefined;
  const candidates = [message.timestamp, isRecord(message.info) ? message.info.timestamp : undefined];
  for (const value of candidates) {
    if (typeof value === "string" && value.trim() !== "") return value;
  }
  return undefined;
}

export function findSentUserPrompts(messages) {
  if (!Array.isArray(messages)) return [];
  const prompts = [];
  for (const message of messages) {
    if (messageRole(message) !== "user") continue;
    const text = extractUserPromptText(message);
    if (text === null) continue;
    const timestamp = messageTimestamp(message);
    prompts.push(timestamp === undefined ? { text } : { text, timestamp });
  }
  return prompts;
}

export function findLastSentUserPrompt(messages) {
  const prompts = findSentUserPrompts(messages);
  const last = prompts[prompts.length - 1];
  return last ? { source: "sent", text: last.text, timestamp: last.timestamp } : null;
}

export function parsePromptSourceArg(args) {
  const trimmed = typeof args === "string" ? args.trim() : "";
  if (trimmed === "") return "sent";
  const lower = trimmed.toLowerCase();
  if (lower === "sent" || lower === "queued" || lower === "pick") return lower;
  const pickMatch = /^pick\s+(.+)$/i.exec(trimmed);
  if (pickMatch) {
    return { pickIndex: pickMatch[1].trim() };
  }
  return { error: `Unknown prompt source "${trimmed}". Use sent, queued, or pick.` };
}

export function promptPreview(text, maxLength = 60) {
  const oneLine = String(text).replace(/\s+/g, " ").trim();
  if (oneLine.length <= maxLength) return oneLine;
  return `${oneLine.slice(0, Math.max(0, maxLength - 1))}\u2026`;
}

function formatRelativeAge(ms) {
  const seconds = Math.max(0, Math.floor(ms / 1000));
  if (seconds < 60) return `${seconds}s`;
  const minutes = Math.floor(seconds / 60);
  if (minutes < 60) return `${minutes}m`;
  const hours = Math.floor(minutes / 60);
  if (hours < 24) return `${hours}h`;
  return `${Math.floor(hours / 24)}d`;
}

function choiceLabel(choice, nowMs) {
  const kind = choice.source === "sent" ? "sent" : "queued";
  let when = "now";
  if (choice.source === "queued" && typeof choice.mtimeMs === "number") {
    when = formatRelativeAge(nowMs - choice.mtimeMs);
  } else if (choice.source === "sent" && typeof choice.timestamp === "string") {
    const ts = Date.parse(choice.timestamp);
    if (!Number.isNaN(ts)) when = formatRelativeAge(nowMs - ts);
  }
  return `${kind} · ${when} · ${promptPreview(choice.text)}`;
}

function parseSentTimestamp(timestamp) {
  if (typeof timestamp !== "string") return null;
  const ms = Date.parse(timestamp);
  return Number.isNaN(ms) ? null : ms;
}

export function buildPromptChoices(sent, queued) {
  const sentChoices = sent.map((prompt, index) => ({
    source: "sent",
    text: prompt.text,
    timestamp: prompt.timestamp,
    index,
    ts: parseSentTimestamp(prompt.timestamp),
  }));
  const queuedChoices = [...queued]
    .sort((a, b) => b.mtimeMs - a.mtimeMs)
    .map((prompt) => ({ source: "queued", text: prompt.text, mtimeMs: prompt.mtimeMs, ts: prompt.mtimeMs }));

  const anySentTimestamp = sentChoices.some((choice) => choice.ts !== null);
  if (!anySentTimestamp) {
    if (sentChoices.length === 1 && queuedChoices.length === 1) {
      return [sentChoices[0], queuedChoices[0]].map(({ source, text, timestamp, mtimeMs }) => ({ source, text, timestamp, mtimeMs }));
    }
    const sentNewestFirst = [...sentChoices].sort((a, b) => b.index - a.index);
    return [...queuedChoices, ...sentNewestFirst].map(({ source, text, timestamp, mtimeMs }) => ({ source, text, timestamp, mtimeMs }));
  }

  const mixed = [
    ...queuedChoices.map((choice) => ({ ...choice, sentIndex: -1 })),
    ...sentChoices.filter((choice) => choice.ts !== null).map((choice) => ({ ...choice, sentIndex: choice.index })),
  ];
  mixed.sort((a, b) => {
    if (b.ts !== a.ts) return b.ts - a.ts;
    if (a.source !== b.source) return a.source === "queued" ? -1 : 1;
    return b.sentIndex - a.sentIndex;
  });
  const untimedSent = sentChoices.filter((choice) => choice.ts === null).sort((a, b) => b.index - a.index);
  return [...mixed, ...untimedSent].map(({ source, text, timestamp, mtimeMs }) => ({ source, text, timestamp, mtimeMs }));
}

export function filterPromptChoices(choices, filter) {
  if (filter === "") return choices;
  const needle = String(filter).toLowerCase();
  return choices.filter((choice) => String(choice.text).toLowerCase().includes(needle));
}

export function formatPromptChoiceList(choices, nowMs = Date.now()) {
  return choices.map((choice, index) => `${index + 1}. ${choiceLabel(choice, nowMs)}`).join("\n");
}

export function selectPromptChoice(choices, index) {
  const raw = typeof index === "string" ? index.trim() : String(index);
  if (!/^\d+$/.test(raw)) {
    return { error: `Invalid index "${raw}". Enter a number from 1 to ${choices.length || 1}.` };
  }
  const n = Number.parseInt(raw, 10);
  if (n < 1 || n > choices.length) {
    return { error: `Index ${n} out of range. Enter a number from 1 to ${choices.length || 1}.` };
  }
  return choices[n - 1];
}

function readArrayValue(source, keys) {
  if (!isRecord(source)) return null;
  for (const key of keys) {
    const value = source[key];
    if (Array.isArray(value)) return value;
    if (typeof value === "function") {
      try {
        const result = value();
        if (Array.isArray(result)) return result;
      } catch {
        // Try next source.
      }
    }
  }
  return null;
}

function readAllSentPromptsFromContext($, deps = {}) {
  if (typeof deps.readAllSentPrompts === "function") return deps.readAllSentPrompts($);
  if (typeof deps.readSentPrompt === "function") {
    const one = deps.readSentPrompt($);
    return one ? [{ text: one.text, timestamp: one.timestamp }] : [];
  }
  const ctx = isRecord($) ? $ : {};
  const candidates = [
    readArrayValue(ctx, ["messages", "history", "turns"]),
    readArrayValue(ctx.session, ["messages", "history", "turns", "getBranch"]),
    readArrayValue(ctx.sessionManager, ["messages", "history", "turns", "getBranch"]),
    readArrayValue(ctx.data?.session?.message, ["list", "get", "sync"]),
    readArrayValue(ctx.conversation, ["messages", "history"]),
  ];
  for (const messages of candidates) {
    if (Array.isArray(messages)) return findSentUserPrompts(messages);
  }
  return [];
}

/**
 * Best-effort read of the last sent user prompt from the mod runtime context.
 * The Claude mod runtime shape is not available in this environment, so this
 * probes common message container locations and accepts injected deps for tests.
 */
export function readSentPromptFromContext($, deps = {}) {
  if (typeof deps.readSentPrompt === "function") return deps.readSentPrompt($);
  const ctx = isRecord($) ? $ : {};
  const candidates = [
    readArrayValue(ctx, ["messages", "history", "turns"]),
    readArrayValue(ctx.session, ["messages", "history", "turns", "getBranch"]),
    readArrayValue(ctx.sessionManager, ["messages", "history", "turns", "getBranch"]),
    readArrayValue(ctx.data?.session?.message, ["list", "get", "sync"]),
    readArrayValue(ctx.conversation, ["messages", "history"]),
  ];
  for (const messages of candidates) {
    const found = findLastSentUserPrompt(messages);
    if (found) return found;
  }
  return null;
}

function readQueuedPromptsFromRoot(root, deps = {}) {
  if (typeof deps.readQueuedPromptList === "function") {
    return deps.readQueuedPromptList(claudeQueuedCommandsDir(root));
  }
  if (typeof deps.readQueuedPromptFile === "function") {
    // Back-compat: custom single-read override (tests) -> synthesize newest.
    const text = deps.readQueuedPromptFile(claudeQueuedCommandsDir(root));
    return text === null ? [] : [{ text, mtimeMs: Date.now() }];
  }
  return readQueuedPromptList(claudeQueuedCommandsDir(root));
}

export function readQueuedPromptFromRoot(root, deps = {}) {
  if (typeof deps.readQueuedPromptFile === "function") {
    const text = deps.readQueuedPromptFile(claudeQueuedCommandsDir(root));
    if (text === null) return null;
    return { source: "queued", text };
  }
  const prompts = readQueuedPromptList(claudeQueuedCommandsDir(root));
  if (prompts.length === 0) return null;
  const newest = [...prompts].sort((a, b) => b.mtimeMs - a.mtimeMs)[0];
  return newest ? { source: "queued", text: newest.text } : null;
}

export function resolvePromptSource(parsed, $, deps = {}) {
  const env = deps.env ?? process.env;
  const root = nucleusUserRoot(deps.platform ?? process.platform, env, deps.homeDir ?? homedir);
  const sentList = readAllSentPromptsFromContext($, deps);
  const queuedList = readQueuedPromptsFromRoot(root, deps);
  const lastSent = sentList[sentList.length - 1]
    ? { source: "sent", text: sentList[sentList.length - 1].text, timestamp: sentList[sentList.length - 1].timestamp }
    : null;
  const newestQueued = [...queuedList].sort((a, b) => b.mtimeMs - a.mtimeMs)[0] ?? null;
  const lastQueued = newestQueued ? { source: "queued", text: newestQueued.text } : null;

  if (parsed === "sent") {
    return lastSent ? { choice: lastSent } : { empty: EMPTY_SESSION_MESSAGE };
  }
  if (parsed === "queued") {
    return lastQueued ? { choice: lastQueued } : { emptyQueued: true };
  }

  const choices = buildPromptChoices(sentList, queuedList);
  if (choices.length === 0) {
    return { empty: EMPTY_SESSION_MESSAGE };
  }
  if (parsed === "pick") {
    const nowMs = typeof deps.now === "function" ? deps.now() : Date.now();
    return { list: formatPromptChoiceList(choices, nowMs), choices };
  }
  if (isRecord(parsed) && typeof parsed.pickIndex === "string") {
    const selected = selectPromptChoice(choices, parsed.pickIndex);
    if (isRecord(selected) && typeof selected.error === "string") {
      return { error: selected.error };
    }
    return { choice: selected };
  }
  return { error: `Unknown prompt source "${String(parsed)}". Use sent, queued, or pick.` };
}

export function resolvePromptChoice(mode, $, deps = {}) {
  const parsed = mode;
  const resolved = resolvePromptSource(parsed, $, deps);
  if (resolved.choice) return resolved.choice;
  if (resolved.empty || resolved.emptyQueued || resolved.list || resolved.error) return null;
  return null;
}

function harnessClipboardCommands() {
  const here = path.dirname(fileURLToPath(import.meta.url));
  const scriptDir = path.join(here, "..", "..", "..", "..", "..", "src", "scripts", "notify");
  return [
    { command: "harness-clipboard", args: [] },
    { command: "bash", args: [path.join(scriptDir, "harness-clipboard.sh")] },
    { command: "pwsh", args: ["-NoProfile", "-File", path.join(scriptDir, "harness-clipboard.ps1")] },
  ];
}

export function clipboardCommands(platform = process.platform) {
  if (platform === "darwin") return [{ command: "pbcopy", args: [] }];
  if (platform === "win32") return [{ command: "clip.exe", args: [] }];
  return [
    { command: "wl-copy", args: [] },
    { command: "xclip", args: ["-selection", "clipboard"] },
  ];
}

export async function defaultWriteToClipboardCommand(command, args, text) {
  try {
    await runFile(command, args, { input: text, timeout: 5000 });
    return true;
  } catch {
    return false;
  }
}

export async function copyTextToClipboard(text, deps = {}) {
  if (typeof deps.copyToClipboard === "function") {
    return deps.copyToClipboard(text);
  }
  const writer = deps.writeToClipboardCommand ?? defaultWriteToClipboardCommand;
  if (!deps.writeToClipboardCommand) {
    for (const candidate of harnessClipboardCommands()) {
      const ok = await writer(candidate.command, candidate.args, text);
      if (ok) return true;
    }
  }
  for (const candidate of clipboardCommands(deps.platform ?? process.platform)) {
    const ok = await writer(candidate.command, candidate.args, text);
    if (ok) return true;
  }
  return false;
}

export function getCommandArgs(event) {
  if (!isRecord(event)) return "";
  if (typeof event.args === "string") return event.args;
  if (typeof event.arguments === "string") return event.arguments;
  if (typeof event.arg === "string") return event.arg;
  if (isRecord(event.command) && typeof event.command.args === "string") return event.command.args;
  return "";
}

export function isRuntimeBusy($, deps = {}) {
  if (typeof deps.isRuntimeBusy === "function") return deps.isRuntimeBusy($);
  const ctx = isRecord($) ? $ : {};
  if (typeof ctx.isIdle === "function") return !ctx.isIdle();
  if (typeof ctx.session?.isIdle === "function") return !ctx.session.isIdle();
  const status = ctx.status ?? ctx.session?.status ?? ctx.data?.session?.status;
  if (typeof status === "string") {
    return status === "running" || status === "busy" || status === "streaming";
  }
  return false;
}

export async function handleCopyUserPrompt(args, $, deps = {}) {
  const parsed = parsePromptSourceArg(args);
  if (isRecord(parsed) && typeof parsed.error === "string") {
    return { text: parsed.error };
  }
  const resolved = resolvePromptSource(parsed, $, deps);
  if (resolved.error) return { text: resolved.error };
  if (resolved.list) return { text: resolved.list };
  if (resolved.emptyQueued) return { text: NOTHING_TO_COPY_QUEUED_MESSAGE };
  if (resolved.empty) return { text: parsed === "queued" ? NOTHING_TO_COPY_QUEUED_MESSAGE : EMPTY_SESSION_MESSAGE };
  if (!resolved.choice) return { text: EMPTY_SESSION_MESSAGE };

  const copied = await copyTextToClipboard(resolved.choice.text, deps);
  if (copied) {
    return { text: `Copied ${resolved.choice.source} prompt to clipboard.` };
  }
  return { text: `Clipboard unavailable. Prompt:\n${resolved.choice.text}` };
}

export async function handleRepeatUserPrompt(args, $, deps = {}) {
  const parsed = parsePromptSourceArg(args);
  if (isRecord(parsed) && typeof parsed.error === "string") {
    return { text: parsed.error };
  }
  const resolved = resolvePromptSource(parsed, $, deps);
  if (resolved.error) return { text: resolved.error };
  if (resolved.list) return { text: resolved.list };
  if (resolved.emptyQueued) return { text: NOTHING_TO_REPEAT_QUEUED_MESSAGE };
  if (resolved.empty) return { text: parsed === "queued" ? NOTHING_TO_REPEAT_QUEUED_MESSAGE : EMPTY_SESSION_MESSAGE };
  if (!resolved.choice) return { text: EMPTY_SESSION_MESSAGE };

  // `command.run` returns `{ text }` to inject the selected prompt as a new
  // user turn. Confirmation during streaming is not verified in mod APIs here.
  return { text: resolved.choice.text };
}

export async function handleContinue(_args, $, deps = {}) {
  const sent = readSentPromptFromContext($, deps);
  if (!sent) {
    return { text: NOTHING_TO_CONTINUE_MESSAGE };
  }
  if (isRuntimeBusy($, deps)) {
    return { text: "Agent is busy." };
  }
  return { text: " " };
}

function defineCommands($) {
  if ($?.command && typeof $.command.register === "function") {
    $.command.register({ name: "continue", description: "Retry or continue the current turn" });
    $.command.register({
      name: "copy-user-prompt",
      description: "Copy a sent or queued prompt (default: sent)",
      argumentHint: "[sent|queued|pick [index]]",
    });
    $.command.register({
      name: "repeat-user-prompt",
      description: "Resubmit a sent or queued prompt as a new user turn (default: sent)",
      argumentHint: "[sent|queued|pick [index]]",
    });
  }
}

function handleCommandRun(name, $, event, deps) {
  const args = getCommandArgs(event);
  if (name === "continue") return handleContinue(args, $, deps);
  if (name === "copy-user-prompt") return handleCopyUserPrompt(args, $, deps);
  if (name === "repeat-user-prompt") return handleRepeatUserPrompt(args, $, deps);
  return undefined;
}

export function registerPromptTools($, on, deps = {}) {
  defineCommands($);

  if (typeof on !== "function") return;

  on("command.run", { command: "continue" }, async (ctx, event) => {
    return handleCommandRun("continue", ctx ?? $, event, deps);
  });
  on("command.run", { command: "copy-user-prompt" }, async (ctx, event) => {
    return handleCommandRun("copy-user-prompt", ctx ?? $, event, deps);
  });
  on("command.run", { command: "repeat-user-prompt" }, async (ctx, event) => {
    return handleCommandRun("repeat-user-prompt", ctx ?? $, event, deps);
  });
}

export function register(on, options = {}) {
  const deps = isRecord(options) && isRecord(options.deps) ? options.deps : options;
  let registeredForStart = false;

  if (typeof on === "function") {
    // Register command.run handlers at module load so command.run events can be
    // handled even if session.start delivers the runtime context separately.
    on("command.run", { command: "continue" }, async (ctx, event) => {
      return handleCommandRun("continue", ctx, event, deps);
    });
    on("command.run", { command: "copy-user-prompt" }, async (ctx, event) => {
      return handleCommandRun("copy-user-prompt", ctx, event, deps);
    });
    on("command.run", { command: "repeat-user-prompt" }, async (ctx, event) => {
      return handleCommandRun("repeat-user-prompt", ctx, event, deps);
    });

    // Register command definitions on session.start with the runtime context.
    on("session.start", async (ctx) => {
      if (registeredForStart) return;
      registeredForStart = true;
      defineCommands(ctx ?? options?.$ ?? options?.context ?? {});
    });
  }

  return { registerPromptTools };
}

export default register;
