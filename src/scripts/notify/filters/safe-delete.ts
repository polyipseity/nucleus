#!/usr/bin/env bun
// safe-delete: one deletion policy for the harness filter runner, the
// safe-delete guard, and the pi extension. It prints exactly one verdict line,
// decision<TAB>rule<TAB>reason, and it classifies the spellings that reach a
// deletion without the interactive alias or the PATH shims: a native path, a
// backslash-escaped word, cmd.exe, find's own primitives, and a bare deletion
// word. A bare word is proven only when it resolves to the home-manager wrapper,
// because that wrapper is the redirect this policy trusts; every other bare word
// is unproven and settings.unproven decides what that gets.
//
//   filters/safe-delete.ts --settings <json> --command <text>
//   filters/safe-delete.ts --settings <json> --hook
//
// The hook mode reads the harness hook JSON on stdin, prints the human message
// to stderr, and exits 2 on deny so the guard keeps its protocol. Every other
// path exits 0, because a filter states its verdict on stdout.
//
// Rule names are the audit contract: native-path, escaped-spelling, cmd-shell,
// find-primitive, proven-redirect, unproven-redirect, no-match.

import { accessSync, constants, readFileSync, readlinkSync, realpathSync, statSync } from "node:fs";
import { basename, join } from "node:path";

export type Decision = "allow" | "ask" | "deny";
export type Rule =
  | "native-path"
  | "escaped-spelling"
  | "cmd-shell"
  | "find-primitive"
  | "proven-redirect"
  | "unproven-redirect"
  | "no-match"
  | "filter-error";

export interface Verdict {
  readonly decision: Decision;
  readonly rule: Rule;
  readonly reason: string;
}

export type RedirectProof =
  | { readonly proven: true; readonly path: string }
  | { readonly proven: false; readonly why: string };
export type RedirectResolver = (word: string) => RedirectProof;

// What the default resolver reads from the environment. The probe is an argument
// rather than a hidden process.env read so a case can prove both outcomes without
// depending on the host's home directory or PATH.
export interface RedirectProbe {
  readonly home: string | null;
  readonly path: string;
  readonly platform: string;
}

export interface PolicyOptions {
  readonly settings: unknown;
  readonly redirect?: RedirectResolver;
}

// A word reached through a prefix whose PATH this repository does not manage, so
// no resolution of the word can prove the wrapper.
type ForcedUnproven = "sudo" | "env-path" | "env-clean" | "command-p";

type Prefix = "sudo" | "env" | "xargs";

interface BareDeletion {
  readonly word: string;
  readonly forced: ForcedUnproven | null;
}

interface CommandFacts {
  readonly native: string[];
  readonly escaped: string[];
  readonly bare: BareDeletion[];
  cmdShell: boolean;
  findPrimitive: boolean;
}

interface Token {
  readonly kind: "word" | "separator";
  readonly text: string;
  readonly quoted: boolean;
}

interface CommandPosition {
  readonly index: number;
  readonly forced: ForcedUnproven | null;
}

const DELETION_WORDS = new Set([
  "rm",
  "del",
  "rd",
  "rmdir",
  "erase",
  "ri",
  "unlink",
  "shred",
  "remove-item",
]);

// A -c string is a script only for an interpreter, so a pattern passed to
// `grep -c 'rm x'` stays an argument and is never re-tokenized as a command.
const SCRIPT_HOSTS = new Set(["sh", "bash", "zsh", "dash", "ksh", "ash", "fish", "pwsh", "powershell"]);

const SCRIPT_OPTION = /^-[A-Za-z]*c[A-Za-z]*$/;
const ASSIGNMENT = /^[A-Za-z_][A-Za-z0-9_]*=/;

// WHY: an option's separate argument hides the command word, so without this table `sudo -u root rm x` reads `root` and reports no-match.
const PREFIX_OPTION_ARGUMENTS: Readonly<Record<Prefix, ReadonlySet<string>>> = {
  sudo: new Set([
    "-u", "--user", "-g", "--group", "-p", "--prompt", "-C", "--close-from",
    "-T", "--command-timeout", "-h", "--host", "-U", "--other-user", "-r", "--role",
    "-t", "--type",
  ]),
  env: new Set(["-u", "--unset", "-C", "--chdir", "-S", "--split-string"]),
  xargs: new Set([
    "-n", "--max-args", "-I", "--replace", "-P", "--max-procs", "-L", "--max-lines",
    "-s", "--max-chars", "-E", "--eof", "-d", "--delimiter", "-a", "--arg-file",
  ]),
};

// A command can nest a script through -c and a substitution, so the walk bounds
// its own recursion rather than trusting input to stay shallow.
const MAX_NESTING = 8;

// WHY: the harness hook convention blocks a tool call with exit status 2, so the
// guard and the filter share one spelling of that status.
const HOOK_DENY_STATUS = 2;

// Aggregation order: a later verdict replaces an earlier one only when its
// decision ranks higher, and the first rule wins a tie.
const DECISION_RANK: Record<Decision, number> = { allow: 1, ask: 2, deny: 3 };

const WRAPPER_MARKER = "home-manager-files/.local/bin";

function isDeletionWord(word: string): boolean {
  return DELETION_WORDS.has(basename(word).toLowerCase());
}

function isCmdSpelling(word: string): boolean {
  const folded = basename(word).toLowerCase();
  return folded === "cmd" || folded === "cmd.exe";
}

function tokenize(command: string): Token[] {
  const tokens: Token[] = [];
  let index = 0;
  while (index < command.length) {
    const char = command[index];
    if (char === " " || char === "\t" || char === "\r") {
      index += 1;
      continue;
    }
    if (char === "\n") {
      tokens.push({ kind: "separator", text: "\n", quoted: false });
      index += 1;
      continue;
    }
    if (char === ";" || char === "&" || char === "|" || char === "(" || char === ")") {
      let end = index + 1;
      if ((char === "&" || char === "|") && command[end] === char) end += 1;
      while (end < command.length && (command[end] === ";" || command[end] === "&" || command[end] === "|")) {
        end += 1;
      }
      tokens.push({ kind: "separator", text: command.slice(index, end), quoted: false });
      index = end;
      continue;
    }

    let text = "";
    let quoted = false;
    while (index < command.length) {
      const current = command[index];
      if (
        current === " " ||
        current === "\t" ||
        current === "\r" ||
        current === "\n" ||
        current === ";" ||
        current === "&" ||
        current === "|" ||
        current === "(" ||
        current === ")"
      ) {
        break;
      }
      if (current === "'" || current === '"') {
        quoted = true;
        const quote = current;
        index += 1;
        while (index < command.length) {
          const inner = command[index];
          if (inner === "\\" && quote === '"' && index + 1 < command.length) {
            text += inner + command[index + 1];
            index += 2;
            continue;
          }
          if (inner === quote) {
            index += 1;
            break;
          }
          text += inner;
          index += 1;
        }
        continue;
      }
      if (current === "\\" && index + 1 < command.length) {
        text += current + command[index + 1];
        index += 2;
        continue;
      }
      if (current === "$" && command[index + 1] === "(") {
        const start = index;
        let depth = 0;
        while (index < command.length) {
          if (command[index] === "\\") {
            index += 2;
            continue;
          }
          if (command[index] === "(") depth += 1;
          if (command[index] === ")") {
            depth -= 1;
            if (depth === 0) {
              index += 1;
              break;
            }
          }
          index += 1;
        }
        text += command.slice(start, index);
        quoted = true;
        continue;
      }
      if (current === "`") {
        const start = index;
        index += 1;
        while (index < command.length) {
          if (command[index] === "\\") {
            index += 2;
            continue;
          }
          if (command[index] === "`") {
            index += 1;
            break;
          }
          index += 1;
        }
        text += command.slice(start, index);
        quoted = true;
        continue;
      }
      text += current;
      index += 1;
    }
    if (text.length > 0 || quoted) tokens.push({ kind: "word", text, quoted });
  }
  return tokens;
}

function commandSubstitutions(word: string): string[] {
  const found: string[] = [];
  let index = 0;
  while (index < word.length) {
    const char = word[index];
    if (char === "\\") {
      index += 2;
      continue;
    }
    if (char === "`") {
      const end = word.indexOf("`", index + 1);
      if (end === -1) break;
      found.push(word.slice(index + 1, end));
      index = end + 1;
      continue;
    }
    if (char === "$" && word[index + 1] === "(") {
      let depth = 0;
      let cursor = index + 1;
      for (; cursor < word.length; cursor += 1) {
        if (word[cursor] === "(") depth += 1;
        if (word[cursor] === ")") {
          depth -= 1;
          if (depth === 0) break;
        }
      }
      if (cursor >= word.length) break;
      found.push(word.slice(index + 2, cursor));
      index = cursor + 1;
      continue;
    }
    index += 1;
  }
  return found;
}

// The invoked word of one simple command, after the prefixes that still leave
// the caller's PATH in charge of what runs.
function locateCommand(segment: readonly Token[]): CommandPosition | null {
  let index = 0;
  let prefix: Prefix | null = null;
  let forced: ForcedUnproven | null = null;

  while (index < segment.length) {
    const word = segment[index]!.text;
    const folded = word.toLowerCase();
    if (prefix === null) {
      if (folded === "sudo" || folded === "env" || folded === "xargs") {
        prefix = folded;
        index += 1;
        continue;
      }
      if (folded === "command") {
        // command -p runs on a default PATH, while -v and -V only probe, so a
        // probe keeps command as the word this walk stops on.
        if (segment[index + 1]?.text === "-p") return { index: index + 2, forced: "command-p" };
        return { index, forced };
      }
      return { index, forced };
    }
    if (folded === "sudo" || folded === "env" || folded === "xargs") return { index, forced };
    if (PREFIX_OPTION_ARGUMENTS[prefix].has(word)) {
      index += 2;
      continue;
    }
    if (word.startsWith("-")) {
      if (prefix === "sudo") forced = "sudo";
      if (prefix === "env" && (folded === "-i" || word === "-")) forced = "env-clean";
      index += 1;
      continue;
    }
    if (ASSIGNMENT.test(word)) {
      if (prefix === "env" && word.startsWith("PATH=")) forced = "env-path";
      index += 1;
      continue;
    }
    return { index, forced: prefix === "sudo" ? "sudo" : forced };
  }
  return null;
}

function recordFindPrimitive(segment: readonly Token[], commandIndex: number, facts: CommandFacts): void {
  for (let index = commandIndex + 1; index < segment.length; index += 1) {
    const word = segment[index]!.text;
    if (word === "-delete") facts.findPrimitive = true;
    if (word !== "-exec" && word !== "-execdir") continue;
    const target = segment[index + 1];
    if (target !== undefined && isDeletionWord(target.text)) facts.findPrimitive = true;
  }
}

function classifyWord(token: Token, forced: ForcedUnproven | null, facts: CommandFacts): void {
  const text = token.text;
  if (text.startsWith("\\") && isDeletionWord(text.slice(1))) {
    facts.escaped.push(text);
    return;
  }
  if (!isDeletionWord(text)) return;
  if (text.includes("/")) {
    facts.native.push(text);
    return;
  }
  facts.bare.push({ word: text, forced });
}

function analyzeSegment(
  segment: readonly Token[],
  depth: number,
  facts: CommandFacts,
  inherited: ForcedUnproven | null,
): void {
  const position = locateCommand(segment);
  const commandToken = position === null ? null : (segment[position.index] ?? null);
  const scriptHost =
    commandToken !== null && SCRIPT_HOSTS.has(basename(commandToken.text).toLowerCase());

  for (let index = 0; index < segment.length; index += 1) {
    const token = segment[index]!;
    if (!token.quoted && isCmdSpelling(token.text)) facts.cmdShell = true;
    // A substitution runs in the caller's shell, so it inherits no prefix PATH.
    for (const nested of commandSubstitutions(token.text)) analyzeCommand(nested, depth + 1, facts, null);
    if (scriptHost && SCRIPT_OPTION.test(token.text) && index + 1 < segment.length) {
      const script = segment[index + 1]!;
      // A prefixed interpreter hands its own environment to the -c script, so the
      // prefix's unproven PATH reaches the inner deletion as well.
      if (script.quoted) analyzeCommand(script.text, depth + 1, facts, position?.forced ?? inherited);
    }
  }

  if (position === null || commandToken === null) return;
  classifyWord(commandToken, position.forced ?? inherited, facts);
  if (basename(commandToken.text).toLowerCase() === "find") recordFindPrimitive(segment, position.index, facts);
}

function analyzeCommand(
  command: string,
  depth: number,
  facts: CommandFacts,
  inherited: ForcedUnproven | null,
): void {
  if (depth > MAX_NESTING) return;
  let segment: Token[] = [];
  for (const token of tokenize(command)) {
    if (token.kind === "separator") {
      if (segment.length > 0) analyzeSegment(segment, depth, facts, inherited);
      segment = [];
      continue;
    }
    segment.push(token);
  }
  if (segment.length > 0) analyzeSegment(segment, depth, facts, inherited);
}

function nativeVerdict(): Verdict {
  return {
    decision: "deny",
    rule: "native-path",
    reason: "native rm bypasses safe-delete protection. Use shell-safe-rm or rip2 instead.",
  };
}

function escapedVerdict(): Verdict {
  return {
    decision: "deny",
    rule: "escaped-spelling",
    reason: "a backslash-escaped deletion command bypasses safe-delete protection. Use shell-safe-rm or rip2 instead.",
  };
}

function cmdShellVerdict(): Verdict {
  return { decision: "deny", rule: "cmd-shell", reason: "cmd.exe is not allowed. Use pwsh instead." };
}

function findPrimitiveVerdict(): Verdict {
  return {
    decision: "deny",
    rule: "find-primitive",
    reason: "find's -delete and -exec primitives run a deletion without the safe-delete wrapper. Use shell-safe-rm or rip2 instead.",
  };
}

function forcedReason(word: string, forced: ForcedUnproven): string {
  switch (forced) {
    case "sudo":
      return `${word} runs behind sudo, whose PATH this repository does not manage`;
    case "env-path":
      return `${word} runs under an env PATH override, whose PATH this repository does not manage`;
    case "env-clean":
      return `${word} runs under env -i, which discards the PATH this repository manages`;
    case "command-p":
      return `${word} runs under command -p, whose default PATH this repository does not manage`;
  }
}

function unprovenVerdict(why: string, unproven: string): Verdict {
  switch (unproven) {
    case "allow":
      return {
        decision: "allow",
        rule: "unproven-redirect",
        reason: `deletion command: ${why}, and settings.unproven allows an unproven redirect`,
      };
    case "ask":
      return {
        decision: "ask",
        rule: "unproven-redirect",
        reason: `deletion command: ${why}, so it is treated as not redirected and the harness prompts`,
      };
    case "deny":
      return {
        decision: "deny",
        rule: "unproven-redirect",
        reason: `deletion command: ${why}, so it is treated as not redirected. Use shell-safe-rm or rip2 instead, or set harness-filters.json safe-delete.settings.unproven to ask or allow.`,
      };
    default:
      return {
        decision: "deny",
        rule: "unproven-redirect",
        reason: `deletion command: ${why}, and settings.unproven is '${unproven}' rather than deny, ask, or allow, so the unproven redirect is denied. Use shell-safe-rm or rip2 instead.`,
      };
  }
}

function bareVerdict(entry: BareDeletion, unproven: string, redirect: RedirectResolver): Verdict {
  if (entry.forced !== null) return unprovenVerdict(forcedReason(entry.word, entry.forced), unproven);
  const proof = redirect(entry.word);
  if (!proof.proven) return unprovenVerdict(proof.why, unproven);
  return {
    decision: "allow",
    rule: "proven-redirect",
    reason: `deletion command: ${entry.word} resolves to the home-manager safe-delete wrapper at ${proof.path}`,
  };
}

function readUnproven(settings: unknown): string {
  if (typeof settings !== "object" || settings === null || Array.isArray(settings)) return "ask";
  const raw = (settings as Record<string, unknown>).unproven;
  if (raw === undefined || raw === null) return "ask";
  return typeof raw === "string" ? raw : JSON.stringify(raw);
}

export function decideDeletion(command: string, options: PolicyOptions): Verdict {
  const unproven = readUnproven(options.settings);
  const redirect = options.redirect ?? managedRedirectResolver(defaultProbe());
  const facts: CommandFacts = { native: [], escaped: [], bare: [], cmdShell: false, findPrimitive: false };
  analyzeCommand(command, 0, facts, null);

  const verdicts: Verdict[] = [];
  if (facts.native.length > 0) verdicts.push(nativeVerdict());
  if (facts.escaped.length > 0) verdicts.push(escapedVerdict());
  if (facts.cmdShell) verdicts.push(cmdShellVerdict());
  if (facts.findPrimitive) verdicts.push(findPrimitiveVerdict());
  for (const entry of facts.bare) verdicts.push(bareVerdict(entry, unproven, redirect));

  let result: Verdict | null = null;
  for (const verdict of verdicts) {
    if (result === null || DECISION_RANK[verdict.decision] > DECISION_RANK[result.decision]) result = verdict;
  }
  return result ?? { decision: "allow", rule: "no-match", reason: "no deletion command" };
}

function realpathOrNull(path: string): string | null {
  try {
    return realpathSync(path);
  } catch {
    return null;
  }
}

function readlinkOrNull(path: string): string | null {
  try {
    return readlinkSync(path);
  } catch {
    return null;
  }
}

function lookupOnPath(word: string, path: string): string | null {
  for (const entry of path.split(":")) {
    if (entry.length === 0) continue;
    const candidate = join(entry, word);
    try {
      if (!statSync(candidate).isFile()) continue;
      accessSync(candidate, constants.X_OK);
      return candidate;
    } catch {
      continue;
    }
  }
  return null;
}

// The managed wrapper is the only redirect the policy trusts, and it is proven
// from three facts: the word resolves on PATH, the resolved file is the wrapper,
// and the wrapper is a symlink into home-manager's file tree. A PowerShell
// session rewrites the word through its alias table, which a filter cannot see,
// so Windows has no provable redirect at all.
export function managedRedirectResolver(probe: RedirectProbe): RedirectResolver {
  return (word: string): RedirectProof => {
    if (probe.platform === "win32") {
      return {
        proven: false,
        why: `${word} has no provable redirect in PowerShell: the deletion shims serve the non-PowerShell contexts, and the profile aliases that redirect the word are invisible to this filter`,
      };
    }
    if (probe.home === null) {
      return { proven: false, why: `${word} has no managed wrapper to compare against because HOME is unset` };
    }
    const wrapper = join(probe.home, ".local", "bin", word);
    const resolved = lookupOnPath(word, probe.path);
    if (resolved === null) return { proven: false, why: `${word} does not resolve on PATH` };
    const wrapperReal = realpathOrNull(wrapper);
    if (wrapperReal === null || realpathOrNull(resolved) !== wrapperReal) {
      return { proven: false, why: `${word} resolves to ${resolved}, not the managed safe-delete wrapper at ${wrapper}` };
    }
    const target = readlinkOrNull(wrapper);
    if (target === null) {
      return {
        proven: false,
        why: `${word} resolves to ${wrapper}, which is a plain file rather than the managed symlink`,
      };
    }
    if (!target.endsWith(`${WRAPPER_MARKER}/${word}`)) {
      return { proven: false, why: `${wrapper} is a symlink to ${target}, not the home-manager wrapper for ${word}` };
    }
    return { proven: true, path: wrapper };
  };
}

function defaultProbe(): RedirectProbe {
  return {
    home: process.env.HOME ?? null,
    path: process.env.PATH ?? "",
    platform: process.platform,
  };
}

function hookCommand(payload: string): string | null {
  let parsed: unknown;
  try {
    parsed = JSON.parse(payload);
  } catch {
    return null;
  }
  if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) return null;
  const record = parsed as Record<string, unknown>;
  if (typeof record.command === "string") return record.command;
  const toolInput = record.tool_input;
  if (typeof toolInput !== "object" || toolInput === null || Array.isArray(toolInput)) return null;
  const command = (toolInput as Record<string, unknown>).command;
  return typeof command === "string" ? command : null;
}

function runHook(settings: unknown): number {
  const command = hookCommand(readFileSync(0, "utf8"));
  if (command === null || command.length === 0) return 0;
  const verdict = decideDeletion(command, { settings });
  if (verdict.decision !== "deny") return 0;
  process.stderr.write(`BLOCKED: ${verdict.reason}\n`);
  return HOOK_DENY_STATUS;
}

function main(argv: readonly string[]): number {
  let settingsText = "{}";
  let command: string | null = null;
  let hook = false;
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];
    if (argument === "--settings") {
      settingsText = argv[index + 1] ?? "";
      index += 1;
      continue;
    }
    if (argument === "--command") {
      command = argv[index + 1] ?? "";
      index += 1;
      continue;
    }
    if (argument === "--hook") {
      hook = true;
      continue;
    }
    process.stdout.write(`ask\tfilter-error\tunknown argument: ${argument}\n`);
    return 0;
  }

  let settings: unknown;
  try {
    settings = JSON.parse(settingsText);
  } catch {
    process.stdout.write("ask\tfilter-error\tsettings are not valid JSON\n");
    return 0;
  }

  if (hook) return runHook(settings);
  const verdict = decideDeletion(command ?? "", { settings });
  process.stdout.write(`${verdict.decision}\t${verdict.rule}\t${verdict.reason}\n`);
  return 0;
}

if (import.meta.main) {
  process.exit(main(process.argv.slice(2)));
}
