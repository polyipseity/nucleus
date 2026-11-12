// The measured deletion-policy corpus: every command from the port's verdict
// table, the settings rows, and the regressions the one implementation has to
// change. Each row carries the decision and rule name the policy must print.
//
// `redirect` says whether a bare deletion word reaches the managed wrapper.
// A case injects a resolver for it, so a row's verdict never depends on the
// host's home directory or PATH: "managed" is a host where the wrapper is
// deployed, "plain" is a host where the word reaches a real deletion binary.

import type { Decision, Rule } from "../../src/scripts/notify/filters/safe-delete.ts";

export type UnprovenSetting = "ask" | "deny" | "allow";
export type RedirectEnvironment = "managed" | "plain";

export interface DeletionCorpusRow {
  readonly command: string;
  readonly unproven: UnprovenSetting;
  readonly decision: Decision;
  readonly rule: Rule;
  readonly redirect: RedirectEnvironment;
  readonly note?: string;
}

export const CORPUS_ROWS: readonly DeletionCorpusRow[] = [
  { command: "rm foo.txt", unproven: "ask", decision: "allow", rule: "proven-redirect", redirect: "managed" },
  { command: "rm -rf build", unproven: "ask", decision: "allow", rule: "proven-redirect", redirect: "managed" },
  { command: "sudo rm foo", unproven: "ask", decision: "ask", rule: "unproven-redirect", redirect: "managed" },
  { command: "/bin/rm foo", unproven: "ask", decision: "deny", rule: "native-path", redirect: "plain" },
  { command: "./rm foo", unproven: "ask", decision: "deny", rule: "native-path", redirect: "plain" },
  { command: "\\rm foo", unproven: "ask", decision: "deny", rule: "escaped-spelling", redirect: "plain" },
  { command: "cmd.exe /c del x", unproven: "ask", decision: "deny", rule: "cmd-shell", redirect: "plain" },
  { command: "ls -la", unproven: "ask", decision: "allow", rule: "no-match", redirect: "plain" },
  { command: "git status", unproven: "ask", decision: "allow", rule: "no-match", redirect: "plain" },
  { command: "git rm foo", unproven: "ask", decision: "allow", rule: "no-match", redirect: "plain" },
  { command: "rip foo", unproven: "ask", decision: "allow", rule: "no-match", redirect: "plain" },
  {
    command: "cat ~/.local/bin/rm",
    unproven: "ask",
    decision: "allow",
    rule: "no-match",
    redirect: "plain",
    note: "the path is an argument to cat, not the executed word",
  },
  { command: "printf '%s' rm", unproven: "ask", decision: "allow", rule: "no-match", redirect: "plain" },
  { command: 'sh -c "/bin/rm foo"', unproven: "ask", decision: "deny", rule: "native-path", redirect: "plain" },
  { command: 'sh -c "rm foo"', unproven: "ask", decision: "allow", rule: "proven-redirect", redirect: "managed" },
  { command: "xargs rm", unproven: "ask", decision: "allow", rule: "proven-redirect", redirect: "managed" },
  { command: "find . -delete", unproven: "ask", decision: "deny", rule: "find-primitive", redirect: "plain" },
  { command: "find . -exec rm {} ;", unproven: "ask", decision: "deny", rule: "find-primitive", redirect: "plain" },
  { command: "/usr/local/bin/rm x", unproven: "deny", decision: "deny", rule: "native-path", redirect: "plain" },
  { command: "/usr/BIN/rm -rf x", unproven: "deny", decision: "deny", rule: "native-path", redirect: "plain" },
  { command: "./RM -rf build", unproven: "deny", decision: "deny", rule: "native-path", redirect: "plain" },
  { command: "\\RM -rf /tmp/x", unproven: "deny", decision: "deny", rule: "escaped-spelling", redirect: "plain" },
  { command: "\\unlink x", unproven: "deny", decision: "deny", rule: "escaped-spelling", redirect: "plain" },
  { command: "pwsh -c x cmd y", unproven: "deny", decision: "deny", rule: "cmd-shell", redirect: "plain" },
  { command: "rm x", unproven: "deny", decision: "deny", rule: "unproven-redirect", redirect: "plain" },
  { command: "rm x", unproven: "ask", decision: "ask", rule: "unproven-redirect", redirect: "plain" },
  { command: "rm x", unproven: "allow", decision: "allow", rule: "unproven-redirect", redirect: "plain" },
  {
    command: 'sh -c "/bin/rm x"',
    unproven: "ask",
    decision: "deny",
    rule: "native-path",
    redirect: "plain",
    note: "regression: a native path inside a quoted -c argument is still the executed word",
  },
  {
    command: "sh -c '/usr/bin/rm x'",
    unproven: "ask",
    decision: "deny",
    rule: "native-path",
    redirect: "plain",
    note: "regression: single quotes hide the same native path from a quote-stripping detector",
  },
  {
    command: 'zsh -c "x; /bin/rm y"',
    unproven: "ask",
    decision: "deny",
    rule: "native-path",
    redirect: "plain",
    note: "regression: the native path is the second command in the -c script",
  },
  {
    command: "zsh -c 'printf x' ; cat ~/.local/bin/rm",
    unproven: "ask",
    decision: "allow",
    rule: "no-match",
    redirect: "plain",
    note: "regression: deletion-shaped text outside the executed position is not a deletion",
  },
];
