/**
 * OpenCode v2 TUI plugin providing prompt tools: /continue, /copy-user-prompt,
 * /repeat-user-prompt. Client-only: it reads TUI session data, shows dialogs,
 * copies to the platform clipboard, and re-submits prompts through the client.
 *
 * Semantics mirror src/users/default/pi/extensions/prompt-tools.ts:
 * - `sent` is the last user-role message sent to the model.
 * - `queued` is the last queued prompt (TUI pending list / harness bridge queue).
 * - `pick` selects between them and always opens dialog.select, even for a
 *   single candidate; cancel is a silent no-op.
 * - copy uses platform clipboard commands with a visible fallback when none works.
 * - repeat resubmits as a new user turn and confirms while running.
 * - empty state prints one line and does nothing else.
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

export function opencodeQueuedCommandsDir(root) {
  return path.join(root, "state", "harness-bridge", "commands", "opencode");
}

/** Read the newest queued harness-bridge prompt without consuming it. */
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

export function extractPendingPromptText(item) {
  if (typeof item === "string") {
    const text = item.trim();
    return text === "" ? null : text;
  }
  if (!isRecord(item)) return null;
  for (const key of ["text", "prompt", "content", "message"]) {
    const value = item[key];
    if (typeof value === "string") {
      const text = value.trim();
      if (text !== "") return text;
    }
    const nested = extractTextContent(value);
    if (nested !== null && nested.trim() !== "") return nested.trim();
  }
  return null;
}

export function findLastQueuedPrompt(pending) {
  if (!Array.isArray(pending)) return null;
  for (let index = pending.length - 1; index >= 0; index -= 1) {
    const text = extractPendingPromptText(pending[index]);
    if (text !== null) return { source: "queued", text };
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

function promptOptionLabel(choice) {
  const label = choice.source === "sent" ? "Sent" : "Queued";
  return `${label}: ${promptPreview(choice.text)}`;
}

async function listData(data, methodNames, args = []) {
  if (!data) return null;
  for (const name of methodNames) {
    const value = data[name];
    if (typeof value === "function") {
      try {
        const result = await value(...args);
        if (Array.isArray(result)) return result;
        if (isRecord(result) && Array.isArray(result.items)) return result.items;
        if (isRecord(result) && Array.isArray(result.data)) return result.data;
        if (isRecord(result) && Array.isArray(result.messages)) return result.messages;
        if (isRecord(result) && Array.isArray(result.pending)) return result.pending;
      } catch {
        // Try next data source.
      }
    }
  }
  return null;
}

export async function readSentPrompt(context, deps = {}) {
  if (typeof deps.readSentPrompt === "function") return deps.readSentPrompt(context);
  const sessionID = deps.sessionID ?? context?.sessionID ?? null;
  const messages = await listData(
    context?.data?.session?.message,
    ["list", "get", "sync"],
    sessionID === null ? [] : [sessionID],
  );
  return findLastSentUserPrompt(messages ?? []);
}

export async function readQueuedPrompt(context, deps = {}) {
  if (typeof deps.readQueuedPrompt === "function") return deps.readQueuedPrompt(context);
  const sessionID = deps.sessionID ?? context?.sessionID ?? null;
  const pending = await listData(
    context?.data?.session?.pending,
    ["list", "get", "sync"],
    sessionID === null ? [] : [sessionID],
  );
  const fromPending = findLastQueuedPrompt(pending ?? []);
  if (fromPending !== null) return fromPending;
  const root = nucleusUserRoot(deps.platform ?? process.platform, deps.env ?? process.env, deps.homeDir ?? homedir);
  const queuedText = (deps.readQueuedPromptFile ?? readQueuedPromptFile)(opencodeQueuedCommandsDir(root));
  if (queuedText === null) return null;
  return { source: "queued", text: queuedText };
}

export async function pickPromptChoice(sent, queued, ui) {
  const choices = [];
  if (sent) choices.push(sent);
  if (queued) choices.push(queued);
  if (choices.length === 0) return null;

  const options = choices.map(promptOptionLabel);
  const select = ui?.dialog?.select;
  if (typeof select !== "function") {
    // No picker available: cannot satisfy "always opens dialog.select".
    return "cancelled";
  }
  const selected = await select({
    title: "Select prompt",
    options: options.map((label, index) => ({ label, value: index })),
    current: 0,
  });
  if (selected === undefined || selected === null) return "cancelled";
  const index = typeof selected === "number" ? selected : Number(selected?.value ?? selected?.index ?? NaN);
  if (!Number.isInteger(index) || index < 0 || index >= choices.length) return "cancelled";
  return choices[index] ?? "cancelled";
}

export async function resolvePromptChoice(mode, context, deps = {}) {
  const sent = await readSentPrompt(context, deps);
  const queued = await readQueuedPrompt(context, deps);
  if (mode === "sent") return sent;
  if (mode === "queued") return queued;
  return pickPromptChoice(sent, queued, context?.ui);
}

function printLine(context, text) {
  const ui = context?.ui;
  if (ui && typeof ui.print === "function") {
    ui.print(text);
    return;
  }
  if (ui && typeof ui.toast === "function") {
    ui.toast(text);
    return;
  }
  if (ui?.toast && typeof ui.toast.show === "function") {
    ui.toast.show({ message: text });
    return;
  }
  if (ui?.notify && typeof ui.notify === "function") {
    ui.notify(text);
    return;
  }
  if (ui?.dialog && typeof ui.dialog.alert === "function") {
    ui.dialog.alert({ title: "prompt-tools", message: text });
    return;
  }
  if (ui?.dialog && typeof ui.dialog.message === "function") {
    ui.dialog.message({ title: "prompt-tools", message: text });
    return;
  }
  if (typeof console !== "undefined" && typeof console.log === "function") {
    console.log(text);
  }
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

export async function defaultWriteToClipboardCommand(command, args, text) {
  try {
    await runFile(command, args, { input: text, timeout: 5000 });
    return true;
  } catch {
    return false;
  }
}

async function isSessionRunning(context, deps = {}) {
  if (typeof deps.isSessionRunning === "function") return deps.isSessionRunning(context);
  const sessionID = deps.sessionID ?? context?.sessionID ?? null;
  const status = await listData(
    context?.data?.session?.status,
    ["get", "list", "sync"],
    sessionID === null ? [] : [sessionID],
  );
  if (Array.isArray(status)) {
    const match = sessionID === null
      ? status[0]
      : status.find((item) => isRecord(item) && (item.sessionID === sessionID || item.id === sessionID));
    const state = isRecord(match) ? (match.status ?? match.state ?? match.value) : null;
    if (typeof state === "string") return state === "running" || state === "busy" || state === "streaming";
  }
  const current = context?.data?.session?.current;
  if (isRecord(current) && typeof current.status === "string") {
    return current.status === "running" || current.status === "busy" || current.status === "streaming";
  }
  return false;
}

async function promptSession(context, text, deps = {}) {
  if (typeof deps.promptSession === "function") return deps.promptSession(context, text);
  const sessionID = deps.sessionID ?? context?.sessionID ?? null;
  const prompt = context?.client?.session?.prompt;
  if (typeof prompt !== "function") return false;
  const attempts = sessionID === null
    ? [{ text }, { prompt: text }, { content: text }]
    : [
        { sessionID, text },
        { sessionID, prompt: text },
        { sessionID, content: text },
        { id: sessionID, text },
      ];
  for (const body of attempts) {
    try {
      await prompt(body);
      return true;
    } catch {
      // Try next call shape.
    }
  }
  return false;
}

export async function handleCopyUserPrompt(args, context, deps = {}) {
  const mode = parsePromptSourceArg(args);
  if (typeof mode === "object") {
    printLine(context, mode.error);
    return;
  }
  const choice = await resolvePromptChoice(mode, context, deps);
  if (choice === "cancelled") return;
  const message = unavailableSourceMessage(mode, "copy", choice);
  if (message) {
    printLine(context, message);
    return;
  }
  if (!choice) {
    printLine(context, EMPTY_SESSION_MESSAGE);
    return;
  }
  const copied = await copyTextToClipboard(choice.text, deps);
  if (copied) {
    printLine(context, `Copied ${choice.source} prompt to clipboard.`);
    return;
  }
  printLine(context, `Clipboard unavailable. Prompt:\n${choice.text}`);
}

export async function handleRepeatUserPrompt(args, context, deps = {}) {
  const mode = parsePromptSourceArg(args);
  if (typeof mode === "object") {
    printLine(context, mode.error);
    return;
  }
  const choice = await resolvePromptChoice(mode, context, deps);
  if (choice === "cancelled") return;
  const message = unavailableSourceMessage(mode, "repeat", choice);
  if (message) {
    printLine(context, message);
    return;
  }
  if (!choice) {
    printLine(context, EMPTY_SESSION_MESSAGE);
    return;
  }

  const running = await isSessionRunning(context, deps);
  if (running) {
    const confirm = context?.ui?.dialog?.confirm;
    let confirmed = false;
    if (typeof confirm === "function") {
      confirmed = Boolean(await confirm({
        title: "Repeat prompt?",
        message: "A turn is running. Resubmit this prompt as a new user turn?",
      }));
    }
    if (!confirmed) return;
  }

  const sent = await promptSession(context, choice.text, deps);
  if (!sent) {
    printLine(context, "Failed to repeat prompt.");
    return;
  }
  if (running) {
    printLine(context, `Queued ${choice.source} prompt as a new turn.`);
  }
}

export async function handleContinue(_args, context, deps = {}) {
  const sent = await readSentPrompt(context, deps);
  if (!sent) {
    printLine(context, NOTHING_TO_CONTINUE_MESSAGE);
    return;
  }
  const running = await isSessionRunning(context, deps);
  if (running) {
    printLine(context, "Agent is busy.");
    return;
  }
  const ok = await promptSession(context, " ", deps);
  if (!ok) {
    printLine(context, "Failed to continue.");
  }
}

export function registerPromptToolsCommands(context, deps = {}) {
  const keymap = context?.keymap;
  const register = keymap?.commands?.register ?? keymap?.registerCommand ?? context?.registerCommand;
  if (typeof register !== "function") return;

  const commands = [
    {
      id: "prompt-tools.continue",
      name: "continue",
      description: "Retry or continue the current turn",
      slash: { name: "continue" },
      run: (args) => handleContinue(args ?? "", context, deps),
      execute: (args) => handleContinue(args ?? "", context, deps),
      handler: (args) => handleContinue(args ?? "", context, deps),
    },
    {
      id: "prompt-tools.copy-user-prompt",
      name: "copy-user-prompt",
      description: "Copy a sent or queued prompt (default: sent)",
      slash: { name: "copy-user-prompt", arguments: true },
      run: (args) => handleCopyUserPrompt(args ?? "", context, deps),
      execute: (args) => handleCopyUserPrompt(args ?? "", context, deps),
      handler: (args) => handleCopyUserPrompt(args ?? "", context, deps),
    },
    {
      id: "prompt-tools.repeat-user-prompt",
      name: "repeat-user-prompt",
      description: "Resubmit a sent or queued prompt as a new user turn (default: sent)",
      slash: { name: "repeat-user-prompt", arguments: true },
      run: (args) => handleRepeatUserPrompt(args ?? "", context, deps),
      execute: (args) => handleRepeatUserPrompt(args ?? "", context, deps),
      handler: (args) => handleRepeatUserPrompt(args ?? "", context, deps),
    },
  ];

  for (const command of commands) {
    register(command);
  }
}

export function createPromptToolsTuiPlugin(deps = {}) {
  return {
    id: "prompt-tools",
    async setup(context) {
      registerPromptToolsCommands(context, deps);
    },
  };
}

export default createPromptToolsTuiPlugin();
