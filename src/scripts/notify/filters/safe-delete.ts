#!/usr/bin/env bun
// safe-delete: one deletion policy for the harness filter runner, the
// safe-delete guard, and the pi extension. It prints exactly one verdict line,
// decision<TAB>rule<TAB>reason, and it classifies the spellings that reach a
// deletion without the interactive alias or the PATH shims: a native path,
// cmd.exe in command position, find's own -delete primitive, and a bare deletion
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
// Rule names are the audit contract: native-path, cmd-shell, find-primitive,
// proven-redirect, unproven-redirect, no-match, filter-error.

import { accessSync, constants, readFileSync, readlinkSync, realpathSync, statSync } from "node:fs";
import { basename, join } from "node:path";

export type Decision = "allow" | "ask" | "deny";
export type Rule =
  | "native-path"
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

// A word that takes the command position without being the executed word, so the
// walk skips it instead of reporting no-match on a shell keyword.
const STATEMENT_WORDS = new Set(["do", "done", "elif", "else", "esac", "fi", "if", "then", "time", "until", "while", "!", "{", "}"]);

// A leading backslash escapes the word name rather than spelling a path, so the
// word it forms is the one that runs.
function stripEscape(word: string): string {
  return word.startsWith("\\") ? word.slice(1) : word;
}

function isDeletionWord(word: string): boolean {
  return DELETION_WORDS.has(basename(word).toLowerCase());
}

function isCmdSpelling(word: string): boolean {
  const folded = basename(stripEscape(word)).toLowerCase();
  return folded === "cmd" || folded === "cmd.exe";
}

interface HeredocSpec {
  readonly delimiter: string;
  readonly stripTabs: boolean;
  // An unquoted delimiter leaves the body expandable, so a command substitution
  // in it still runs. A quote or backslash in the delimiter word turns expansion
  // off for the whole body.
  readonly expandable: boolean;
}

// A `#` comment and a `((` arithmetic group only open at the start of a word, so
// `x#y` and `x((y))` stay part of a word.
const WORD_BREAK = new Set([" ", "\t", "\r", "\n", ";", "&", "|", "(", ")"]);

function atWordStart(command: string, index: number): boolean {
  return index === 0 || WORD_BREAK.has(command[index - 1]!);
}

// The heredoc operator has consumed everything up to `start`; this reads the
// delimiter word and reports where it ends. The delimiter is quote-removed, so
// `<<'EOF'`, `<<"EOF"`, and `<<EOF` all end the body at the same line.
function readHeredocDelimiter(command: string, start: number): { spec: HeredocSpec; end: number } | null {
  let index = start;
  let stripTabs = false;
  if (command[index] === "-") {
    stripTabs = true;
    index += 1;
  }
  while (command[index] === " " || command[index] === "\t") index += 1;
  let delimiter = "";
  let sawWord = false;
  let literal = false;
  while (index < command.length) {
    const char = command[index]!;
    if (
      char === " " ||
      char === "\t" ||
      char === "\r" ||
      char === "\n" ||
      char === ";" ||
      char === "&" ||
      char === "|" ||
      char === "(" ||
      char === ")"
    ) {
      break;
    }
    if (char === "'" || char === '"') {
      const quote = char;
      literal = true;
      index += 1;
      while (index < command.length && command[index] !== quote) {
        delimiter += command[index];
        index += 1;
      }
      if (index < command.length) index += 1;
      sawWord = true;
      continue;
    }
    if (char === "\\" && index + 1 < command.length) {
      delimiter += command[index + 1];
      index += 2;
      sawWord = true;
      literal = true;
      continue;
    }
    delimiter += char;
    index += 1;
    sawWord = true;
  }
  if (!sawWord) return null;
  return { spec: { delimiter, stripTabs, expandable: !literal }, end: index };
}

// Returns the index just past the delimiter line, or null when the body never
// terminates. `<<-` strips leading tabs from each body line before comparing, and
// a trailing carriage return is stripped so a CRLF file still ends the body.
function skipHeredocBody(command: string, start: number, spec: HeredocSpec): number | null {
  let index = start;
  while (index < command.length) {
    const newline = command.indexOf("\n", index);
    const lineEnd = newline === -1 ? command.length : newline;
    const raw = command.slice(index, lineEnd);
    const tabStripped = spec.stripTabs ? raw.replace(/^\t+/, "") : raw;
    const line = tabStripped.endsWith("\r") ? tabStripped.slice(0, -1) : tabStripped;
    if (line === spec.delimiter) return newline === -1 ? command.length : newline + 1;
    if (newline === -1) return null;
    index = newline + 1;
  }
  return null;
}

// A heredoc body is data rather than commands, so it is dropped before the
// tokenizer turns its lines into segments. Bodies are consumed in the order the
// operators appear on their line, and an unterminated heredoc drops the rest.
function stripHeredocBodies(command: string): string {
  let result = "";
  let index = 0;
  let quote: string | null = null;
  let pending: HeredocSpec[] = [];
  while (index < command.length) {
    const char = command[index]!;
    if (quote !== null) {
      result += char;
      if (char === "\\" && quote === '"' && index + 1 < command.length) {
        result += command[index + 1];
        index += 2;
        continue;
      }
      if (char === quote) quote = null;
      index += 1;
      continue;
    }
    if (char === "'" || char === '"') {
      quote = char;
      result += char;
      index += 1;
      continue;
    }
    if (char === "\\") {
      result += command.slice(index, index + 2);
      index += 2;
      continue;
    }
    if (char === "$" && command[index + 1] === "(" && command[index + 2] === "(") {
      // WHY: `<<` in $(( )) is a shift, so the expression is copied whole rather
      // than read as a redirection that waits for a body line.
      const start = index;
      let depth = 2;
      index += 3;
      while (index < command.length && depth > 0) {
        if (command[index] === "(") depth += 1;
        if (command[index] === ")") depth -= 1;
        index += 1;
      }
      result += command.slice(start, index);
      continue;
    }
    if (char === "(" && command[index + 1] === "(" && atWordStart(command, index)) {
      // WHY: `<<` in an arithmetic command is a shift, so the group is copied
      // whole rather than read as a redirection that waits for a body line.
      const start = index;
      let depth = 2;
      index += 2;
      while (index < command.length && depth > 0) {
        if (command[index] === "(") depth += 1;
        if (command[index] === ")") depth -= 1;
        index += 1;
      }
      result += command.slice(start, index);
      continue;
    }
    if (char === "#" && atWordStart(command, index)) {
      // A comment runs to the newline, so an operator inside it opens nothing.
      const newline = command.indexOf("\n", index);
      const end = newline === -1 ? command.length : newline;
      result += command.slice(index, end);
      index = end;
      continue;
    }
    if (char === "<" && command[index + 1] === "<") {
      // `<<<` is a herestring with no body.
      if (command[index + 2] === "<") {
        result += "<<<";
        index += 3;
        continue;
      }
      const read = readHeredocDelimiter(command, index + 2);
      if (read === null) {
        result += "<<";
        index += 2;
        continue;
      }
      result += command.slice(index, read.end);
      pending.push(read.spec);
      index = read.end;
      continue;
    }
    if (char === "\n") {
      result += "\n";
      index += 1;
      for (const spec of pending) {
        const bodyStart = index;
        const next = skipHeredocBody(command, index, spec);
        if (spec.expandable) {
          // An unquoted delimiter expands command substitutions, so a deletion
          // inside one is live even though the rest of the body is data.
          const body = command.slice(bodyStart, next === null ? command.length : next);
          for (const nested of commandSubstitutions(body)) result += `${nested}\n`;
        }
        if (next === null) return result;
        index = next;
      }
      pending = [];
      continue;
    }
    result += char;
    index += 1;
  }
  return result;
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
        const next = segment[index + 1]?.text;
        if (next === "-p") {
          index += 2;
          if (segment[index]?.text === "--") index += 1;
          return { index, forced: "command-p" };
        }
        if (next === "-v" || next === "-V") return { index, forced };
        index += 1;
        if (segment[index]?.text === "--") index += 1;
        continue;
      }
      // WHY: a statement word and a leading assignment take the command position
      // without being the executed word, and stopping on either hides a deletion.
      if (STATEMENT_WORDS.has(folded) || ASSIGNMENT.test(word)) {
        index += 1;
        continue;
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

const EXEC_TERMINATORS = new Set([";", "\\;", "+"]);

// find runs the words after -exec as a command, so they are classified the way a
// top-level word is: a bare rm is proven or unproven through PATH, a native path
// denies, and an interpreter -c script recurses. A missing terminator takes the
// rest of the segment.
function analyzeFind(
  segment: readonly Token[],
  commandIndex: number,
  depth: number,
  facts: CommandFacts,
  inherited: ForcedUnproven | null,
): void {
  for (let index = commandIndex + 1; index < segment.length; index += 1) {
    const word = segment[index]!.text;
    if (word === "-delete") facts.findPrimitive = true;
    if (word !== "-exec" && word !== "-execdir") continue;
    let end = index + 1;
    while (end < segment.length && !EXEC_TERMINATORS.has(segment[end]!.text)) end += 1;
    if (end > index + 1) analyzeSegment(segment.slice(index + 1, end), depth + 1, facts, inherited);
    index = end;
  }
}

function classifyWord(token: Token, forced: ForcedUnproven | null, facts: CommandFacts): void {
  const text = stripEscape(token.text);
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
  // WHY: find -exec re-analysis reaches this walk without passing analyzeCommand,
  // so the nesting cap belongs here as well as there.
  if (depth > MAX_NESTING) return;
  const position = locateCommand(segment);
  const commandToken = position === null ? null : (segment[position.index] ?? null);
  const commandWord = commandToken === null ? null : basename(stripEscape(commandToken.text)).toLowerCase();
  const scriptHost = commandWord !== null && SCRIPT_HOSTS.has(commandWord);

  for (let index = 0; index < segment.length; index += 1) {
    const token = segment[index]!;
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
  // Only the command word names the shell, so `echo cmd` keeps cmd as an argument.
  if (isCmdSpelling(commandToken.text)) facts.cmdShell = true;
  classifyWord(commandToken, position.forced ?? inherited, facts);
  if (commandWord === "find") analyzeFind(segment, position.index, depth, facts, position.forced ?? inherited);
}

function analyzeCommand(
  command: string,
  depth: number,
  facts: CommandFacts,
  inherited: ForcedUnproven | null,
): void {
  if (depth > MAX_NESTING) return;
  let segment: Token[] = [];
  for (const token of tokenize(stripHeredocBodies(command))) {
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

function cmdShellVerdict(): Verdict {
  return { decision: "deny", rule: "cmd-shell", reason: "cmd.exe is not allowed. Use pwsh instead." };
}

function findPrimitiveVerdict(): Verdict {
  return {
    decision: "deny",
    rule: "find-primitive",
    reason: "find -delete runs a deletion without the safe-delete wrapper. Use shell-safe-rm or rip2 instead.",
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
  const facts: CommandFacts = { native: [], bare: [], cmdShell: false, findPrimitive: false };
  analyzeCommand(command, 0, facts, null);

  const verdicts: Verdict[] = [];
  if (facts.native.length > 0) verdicts.push(nativeVerdict());
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
