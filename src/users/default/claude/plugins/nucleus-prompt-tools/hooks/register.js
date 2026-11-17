/**
 * Claude Code mod providing prompt tools: /continue, /copy-user-prompt,
 * /repeat-user-prompt.
 *
 * Semantics mirror src/users/default/pi/extensions/prompt-tools.ts:
 * - `sent` is the last user-role message sent to the model.
 * - `queued` is the newest queued harness-bridge prompt for Claude, read
 *   without consuming it from
 *   <nucleus user root>/state/harness-bridge/commands/claude/*.json.
 * - `pick` selects between sent and queued. A general mod dialog picker API is
 *   not verified from authoritative docs available in this environment, so
 *   `pick` resolves deterministically (queued if present, otherwise sent) and
 *   the task report records that limitation and evidence. No dialog API is
 *   called.
 * - copy copies to the platform clipboard as a side effect with a visible
 *   fallback when no clipboard command works.
 * - repeat returns the selected prompt as `{ text }` so command.run injects it
 *   as a new user turn.
 * - continue returns `{ text: " " }` to continue/retry the turn when a sent
 *   message exists and the runtime is idle; otherwise it returns a one-line
 *   message and does nothing else.
 * - empty state returns one line and does nothing else.
 */

import { execFile } from "node:child_process";
import { readdirSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import path from "node:path";
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
    const queued = JSON.parse(readFileSync(path.join(commandsDir, newest), "utf8"));
    if (typeof queued.text === "string") {
      const text = queued.text.trim();
      return text === "" ? null : text;
    }
    return null;
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

export function findLastSentUserPrompt(messages) {
  if (!Array.isArray(messages)) return null;
  for (let index = messages.length - 1; index >= 0; index -= 1) {
    const message = messages[index];
    if (messageRole(message) !== "user") continue;
    const text = extractUserPromptText(message);
    if (text === null) continue;
    return { source: "sent", text };
  }
  return null;
}

export function parsePromptSourceArg(args) {
  const trimmed = typeof args === "string" ? args.trim() : "";
  if (trimmed === "") return "sent";
  const lower = trimmed.toLowerCase();
  if (lower === "sent" || lower === "queued" || lower === "pick") return lower;
  return { error: `Unknown prompt source "${trimmed}". Use sent, queued, or pick.` };
}

export function promptPreview(text, maxLength = 60) {
  const oneLine = String(text).replace(/\s+/g, " ").trim();
  if (oneLine.length <= maxLength) return oneLine;
  return `${oneLine.slice(0, Math.max(0, maxLength - 1))}\u2026`;
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

export function readQueuedPromptFromRoot(root, deps = {}) {
  const queuedText = (deps.readQueuedPromptFile ?? readQueuedPromptFile)(claudeQueuedCommandsDir(root));
  if (queuedText === null) return null;
  return { source: "queued", text: queuedText };
}

export function resolvePromptChoice(mode, $, deps = {}) {
  const sent = readSentPromptFromContext($, deps);
  const env = deps.env ?? process.env;
  const root = nucleusUserRoot(deps.platform ?? process.platform, env, deps.homeDir ?? homedir);
  const queued = readQueuedPromptFromRoot(root, deps);

  if (mode === "sent") return sent;
  if (mode === "queued") return queued;

  // Deterministic `pick`: no verified mod dialog picker API is available in
  // this environment (plan states dialog.select not clearly documented and no
  // authoritative dialog API was found in-repo), so prefer queued when
  // present, otherwise sent. Limitation documented in the task report.
  if (queued) return queued;
  if (sent) return sent;
  return null;
}

function unavailableSourceMessage(mode, command, choice) {
  if (choice !== null) return null;
  if (mode === "queued") {
    return command === "copy" ? NOTHING_TO_COPY_QUEUED_MESSAGE : NOTHING_TO_REPEAT_QUEUED_MESSAGE;
  }
  return EMPTY_SESSION_MESSAGE;
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
  const mode = parsePromptSourceArg(args);
  if (typeof mode === "object") {
    return { text: mode.error };
  }
  const choice = resolvePromptChoice(mode, $, deps);
  const message = unavailableSourceMessage(mode, "copy", choice);
  if (message) {
    return { text: message };
  }
  if (!choice) {
    return { text: EMPTY_SESSION_MESSAGE };
  }

  const copied = await copyTextToClipboard(choice.text, deps);
  if (copied) {
    return { text: `Copied ${choice.source} prompt to clipboard.` };
  }
  return { text: `Clipboard unavailable. Prompt:\n${choice.text}` };
}

export async function handleRepeatUserPrompt(args, $, deps = {}) {
  const mode = parsePromptSourceArg(args);
  if (typeof mode === "object") {
    return { text: mode.error };
  }
  const choice = resolvePromptChoice(mode, $, deps);
  const message = unavailableSourceMessage(mode, "repeat", choice);
  if (message) {
    return { text: message };
  }
  if (!choice) {
    return { text: EMPTY_SESSION_MESSAGE };
  }

  // `command.run` returns `{ text }` to inject the selected prompt as a new
  // user turn. Confirmation during streaming is not verified in mod APIs here.
  return { text: choice.text };
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
      argumentHint: "[sent|queued|pick]",
    });
    $.command.register({
      name: "repeat-user-prompt",
      description: "Resubmit a sent or queued prompt as a new user turn (default: sent)",
      argumentHint: "[sent|queued|pick]",
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
