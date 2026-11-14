#!/usr/bin/env bun
// safe-delete: one deletion policy for the harness filter runner, the
// safe-delete guard, and the pi extension. It prints exactly one verdict line,
// decision<TAB>rule<TAB>reason, and it classifies the spellings that reach a
// deletion without the interactive alias or the PATH shims: a native path,
// cmd.exe in command position, find's own -delete primitive, and a bare deletion
// word. A bare word is proven only when it resolves to a redirect this policy
// trusts: the home-manager wrapper on POSIX, or on Windows a shim the manifest
// lists with rip.exe's hash, or the managed PowerShell profile for the words it
// overrides. Every other bare word is unproven and settings.unproven decides what
// that gets.
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

import { createHash } from "node:crypto";
import { accessSync, constants, readFileSync, readlinkSync, realpathSync, statSync } from "node:fs";
import { basename, join, win32 } from "node:path";

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

// A proven redirect names the mechanism, because each mechanism is proven from
// different facts and the reason a human reads names that mechanism.
export type RedirectProof =
  | { readonly proven: true; readonly via: "wrapper" | "shim"; readonly path: string }
  | { readonly proven: true; readonly via: "profile" }
  | { readonly proven: false; readonly why: string };
export type RedirectResolver = (word: string) => RedirectProof;

// What the default resolver reads from the environment. The probe is an argument
// rather than a hidden process.env read so a case can prove both outcomes without
// depending on the host's home directory, PATH, or deployed manifest.
export interface RedirectProbe {
  readonly home: string | null;
  readonly path: string;
  readonly platform: string;
  // The shim manifest Sync-SafeDelete writes, and the extension order Windows
  // resolves a word through.
  readonly manifest?: string | null;
  readonly pathext?: string;
  // Whether the managed PowerShell profile is assumed loaded.
  readonly powershell?: "profile" | "none";
  readonly noProfile?: boolean;
}

export interface PolicyOptions {
  readonly settings: unknown;
  readonly redirect?: RedirectResolver;
  readonly platform?: string;
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
  readonly platform: string;
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

// The words the managed PowerShell profile rewrites into its recycle-bin function.
// `rm` is not one of them on Windows: it is a deployed shim there, so it keeps the
// manifest proof.
const POWERSHELL_WORDS = new Set(["remove-item", "ri", "del", "rd", "erase"]);

const WIN32_EXECUTABLE_EXTENSIONS = [".exe", ".cmd", ".bat", ".com"];

// The Windows default, used when PATHEXT is unset.
const DEFAULT_PATHEXT = ".COM;.EXE;.BAT;.CMD";

// Aggregation order: a later verdict replaces an earlier one only when its
// decision ranks higher, and the first rule wins a tie.
const DECISION_RANK: Record<Decision, number> = { allow: 1, ask: 2, deny: 3 };

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

const WRAPPER_MARKER = "home-manager-files/.local/bin";

// A word that takes the command position without being the executed word, so the
// walk skips it instead of reporting no-match on a shell keyword.
const STATEMENT_WORDS = new Set(["do", "done", "elif", "else", "esac", "fi", "if", "then", "time", "until", "while", "!", "{", "}"]);

// A leading backslash escapes the word name rather than spelling a path, so the
// word it forms is the one that runs. Windows has no such escape: there a
// backslash separates path components.
function stripEscape(word: string): string {
  return word.startsWith("\\") ? word.slice(1) : word;
}

// A Windows command word carries its executable extension, so RM.EXE names the
// same deletion as rm and pwsh.exe the same interpreter as pwsh.
function foldWin32Name(name: string): string {
  const folded = name.toLowerCase();
  for (const extension of WIN32_EXECUTABLE_EXTENSIONS) {
    if (folded.endsWith(extension)) return folded.slice(0, -extension.length);
  }
  return folded;
}

// The name a word runs under on this platform, with that platform's escape and
// executable-extension rules.
function commandBase(word: string, platform: string): string {
  if (platform === "win32") return foldWin32Name(win32.basename(word));
  return basename(stripEscape(word)).toLowerCase();
}

function isDeletionWord(word: string, platform: string): boolean {
  return DELETION_WORDS.has(commandBase(word, platform));
}

function isCmdSpelling(word: string, platform: string): boolean {
  const folded = commandBase(word, platform);
  // WHY: cmd.exe keeps its extension on POSIX, where the name is not native, so
  // both spellings name the shell there.
  return folded === "cmd" || (platform !== "win32" && folded === "cmd.exe");
}

function isNativePath(word: string, platform: string): boolean {
  if (platform === "win32") {
    return word.includes("\\") || word.includes("/") || /^[A-Za-z]:/.test(word);
  }
  return word.includes("/");
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
        // A PATH assignment replaces the PATH the wrapper lives on, so the word
        // that follows cannot be proven by probing this process's PATH.
        if (word.startsWith("PATH=")) forced = "env-path";
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
  const platform = facts.platform;
  const text = platform === "win32" ? token.text : stripEscape(token.text);
  if (!isDeletionWord(text, platform)) return;
  if (isNativePath(text, platform)) {
    facts.native.push(text);
    return;
  }
  // A Windows word is probed and listed without its executable extension, so
  // `rm.exe` and `rm` reach the same shim.
  facts.bare.push({ word: platform === "win32" ? commandBase(text, platform) : text, forced });
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
  const commandWord = commandToken === null ? null : commandBase(commandToken.text, facts.platform);
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
  if (isCmdSpelling(commandToken.text, facts.platform)) facts.cmdShell = true;
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
  switch (proof.via) {
    case "wrapper":
      return {
        decision: "allow",
        rule: "proven-redirect",
        reason: `deletion command: ${entry.word} resolves to the home-manager safe-delete wrapper at ${proof.path}`,
      };
    case "shim":
      return {
        decision: "allow",
        rule: "proven-redirect",
        reason: `deletion command: ${entry.word} resolves to the deployed rip shim at ${proof.path}, whose hash matches the shim manifest`,
      };
    case "profile":
      return {
        decision: "allow",
        rule: "proven-redirect",
        reason: `deletion command: ${entry.word} is redirected by the managed PowerShell profile, which overrides the deletion words`,
      };
  }
}

function readUnproven(settings: unknown): string {
  if (typeof settings !== "object" || settings === null || Array.isArray(settings)) return "ask";
  const raw = (settings as Record<string, unknown>).unproven;
  if (raw === undefined || raw === null) return "ask";
  return typeof raw === "string" ? raw : JSON.stringify(raw);
}

// The managed profile is assumed loaded unless the setting says otherwise, so an
// absent or invalid value keeps the redirect proof the profile provides.
function readPowershell(settings: unknown): "profile" | "none" {
  if (typeof settings !== "object" || settings === null || Array.isArray(settings)) return "profile";
  return (settings as Record<string, unknown>).powershell === "none" ? "none" : "profile";
}

// A session started with -NoProfile discards the managed profile, so the redirect
// it provides is absent from that command. The spelling is matched anywhere in
// the command, because an outer interpreter may hand it to an inner one.
export function hasNoProfile(command: string): boolean {
  return /-no(?:profile|p)\b/i.test(command);
}

export function decideDeletion(command: string, options: PolicyOptions): Verdict {
  const unproven = readUnproven(options.settings);
  const platform = options.platform ?? process.platform;
  const redirect =
    options.redirect ??
    managedRedirectResolver({
      ...defaultProbe(),
      platform,
      powershell: readPowershell(options.settings),
      noProfile: hasNoProfile(command),
    });
  const facts: CommandFacts = { platform, native: [], bare: [], cmdShell: false, findPrimitive: false };
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

// The shim manifest Sync-SafeDelete writes: one entry per deployed copy, plus the
// hash of the rip.exe those copies were made from.
interface ShimEntry {
  readonly name: string;
  readonly path: string;
}

interface ShimManifest {
  readonly ripHash: string;
  readonly shims: readonly ShimEntry[];
}

interface Win32Resolved {
  readonly name: string;
  readonly path: string;
}

// A failed read answers with the reason, which is what the unproven verdict shows.
// Any shape this policy cannot trust is a reason, never an empty manifest.
function readShimManifest(manifestPath: string | null): ShimManifest | string {
  if (manifestPath === null) return "the shim manifest path is unknown because LOCALAPPDATA is unset";
  let text: string;
  try {
    text = readFileSync(manifestPath, "utf8");
  } catch {
    return `the shim manifest at ${manifestPath} is missing`;
  }
  let parsed: unknown;
  try {
    parsed = JSON.parse(text);
  } catch {
    return `the shim manifest at ${manifestPath} is not valid JSON`;
  }
  if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) {
    return `the shim manifest at ${manifestPath} is not an object`;
  }
  const record = parsed as Record<string, unknown>;
  if (record.version !== 1) return `the shim manifest at ${manifestPath} is not version 1`;
  if (typeof record.ripHash !== "string" || record.ripHash.length === 0) {
    return `the shim manifest at ${manifestPath} carries no ripHash`;
  }
  if (!Array.isArray(record.shims)) return `the shim manifest at ${manifestPath} carries no shim list`;
  const shims: ShimEntry[] = [];
  for (const shim of record.shims) {
    if (typeof shim !== "object" || shim === null || Array.isArray(shim)) continue;
    const { name, path } = shim as Record<string, unknown>;
    if (typeof name !== "string" || typeof path !== "string") continue;
    shims.push({ name, path });
  }
  return { ripHash: record.ripHash, shims };
}

// Windows compares paths without regard to case, and either separator may appear.
function normalizeWin32Path(path: string): string {
  return path.replace(/\//g, "\\").toLowerCase();
}

function win32CandidateNames(word: string, pathext: string): string[] {
  const folded = word.toLowerCase();
  const extensions = pathext
    .split(";")
    .map((entry) => entry.trim())
    .filter((entry) => entry.length > 0);
  if (extensions.some((extension) => folded.endsWith(extension.toLowerCase()))) return [word];
  return extensions.map((extension) => `${word}${extension}`);
}

// Windows resolves a word through PATHEXT, entry by entry, so the first file that
// exists wins and the extension it was found under is part of its name.
function lookupOnWin32Path(word: string, path: string, pathext: string): Win32Resolved | null {
  const candidates = win32CandidateNames(word, pathext);
  for (const rawEntry of path.split(";")) {
    const entry = rawEntry.trim().replace(/^"(.*)"$/, "$1");
    if (entry.length === 0) continue;
    for (const name of candidates) {
      const candidate = join(entry, name);
      try {
        if (!statSync(candidate).isFile()) continue;
        return { name, path: candidate };
      } catch {
        continue;
      }
    }
  }
  return null;
}

function sha256OrNull(path: string): string | null {
  try {
    return createHash("sha256").update(readFileSync(path)).digest("hex");
  } catch {
    return null;
  }
}

// A deployed shim is a copy of rip.exe rather than a symlink, so a realpath
// comparison proves nothing. The manifest records where the copies were written
// and the bytes they were made from, and only a match on both proves the shim.
function win32ShimProof(word: string, probe: RedirectProbe, manifest: ShimManifest | string): RedirectProof {
  const resolved = lookupOnWin32Path(word, probe.path, probe.pathext ?? DEFAULT_PATHEXT);
  if (resolved === null) return { proven: false, why: `${word} does not resolve on a PATH entry` };
  if (typeof manifest === "string") {
    return { proven: false, why: `${word} resolves to ${resolved.path}, but ${manifest}` };
  }
  const listed = manifest.shims.some(
    (shim) =>
      shim.name.toLowerCase() === resolved.name.toLowerCase() &&
      normalizeWin32Path(shim.path) === normalizeWin32Path(resolved.path),
  );
  if (!listed) {
    return { proven: false, why: `${word} resolves to ${resolved.path}, which the shim manifest does not list` };
  }
  const hash = sha256OrNull(resolved.path);
  if (hash === null) return { proven: false, why: `${resolved.path} could not be read for the shim hash check` };
  if (hash !== manifest.ripHash.toLowerCase()) {
    return {
      proven: false,
      why: `${resolved.path} does not match the rip.exe hash in the shim manifest, so the shim is stale`,
    };
  }
  return { proven: true, via: "shim", path: resolved.path };
}

// A bare word is proven when it reaches a redirect this policy trusts: the
// home-manager wrapper on POSIX, or on Windows a shim the manifest lists with
// rip.exe's hash or the managed PowerShell profile for the words it overrides.
export function managedRedirectResolver(probe: RedirectProbe): RedirectResolver {
  let manifest: ShimManifest | string | null = null;
  return (word: string): RedirectProof => {
    if (probe.noProfile === true) {
      return {
        proven: false,
        why: `${word} runs in a session started with -NoProfile, which discards the managed profile`,
      };
    }
    if (probe.platform === "win32") {
      // The profile proof belongs to the words the profile rewrites, and those
      // words keep their shims, so turning the assumption off falls through to
      // the manifest rather than making the word unprovable.
      if (POWERSHELL_WORDS.has(word.toLowerCase()) && (probe.powershell ?? "profile") !== "none") {
        return { proven: true, via: "profile" };
      }
      if (manifest === null) manifest = readShimManifest(probe.manifest ?? null);
      return win32ShimProof(word, probe, manifest);
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
    return { proven: true, via: "wrapper", path: wrapper };
  };
}

function defaultProbe(): RedirectProbe {
  const localAppData = process.env.LOCALAPPDATA;
  return {
    home: process.env.USERPROFILE ?? process.env.HOME ?? null,
    manifest:
      localAppData === undefined || localAppData.length === 0
        ? null
        : join(localAppData, "nucleus", "state", "safe-delete", "shims.json"),
    path: process.env.PATH ?? "",
    pathext: process.env.PATHEXT ?? DEFAULT_PATHEXT,
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
