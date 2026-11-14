// Cases for the one deletion policy: the measured corpus, the settings knob, the
// redirect proof against a fixture home, and both CLI modes. A corpus row
// injects the resolver its `redirect` field names, so the suite reaches the same
// verdicts on a host where the managed wrapper does not exist; the proof cases
// build their own wrapper tree, so they never read the host's home directory.

import { describe, expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { chmodSync, mkdirSync, mkdtempSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  decideDeletion,
  hasNoProfile,
  managedRedirectResolver,
  type RedirectProbe,
  type RedirectResolver,
  type Verdict,
} from "../../../src/scripts/notify/filters/safe-delete.ts";
import { CORPUS_ROWS } from "../../fixtures/safe-delete-corpus.ts";

const FILTER = join(import.meta.dir, "../../../src/scripts/notify/filters/safe-delete.ts");

const managedResolver: RedirectResolver = (word) => ({
  proven: true,
  via: "wrapper",
  path: `/nix/store/0123456789ab-home-manager-files/.local/bin/${word}`,
});

const plainResolver: RedirectResolver = (word) => ({ proven: false, why: `${word} does not resolve on PATH` });

function fixtureHome(): string {
  return mkdtempSync(join(tmpdir(), "safe-delete-home-"));
}

function writeExecutable(path: string): void {
  writeFileSync(path, "#!/bin/sh\nexit 0\n");
  chmodSync(path, 0o755);
}

// A home whose .local/bin/<word> is the link home-manager deploys, plus the
// fixture store tree it points into.
function managedHome(word: string): { home: string; wrapperDir: string } {
  const home = fixtureHome();
  const storeBin = join(home, "store", "0123456789ab-home-manager-files", ".local", "bin");
  const wrapperDir = join(home, ".local", "bin");
  mkdirSync(storeBin, { recursive: true });
  mkdirSync(wrapperDir, { recursive: true });
  writeExecutable(join(storeBin, word));
  symlinkSync(join(storeBin, word), join(wrapperDir, word));
  return { home, wrapperDir };
}

function emptyPath(home: string): string {
  const path = join(home, "bin");
  mkdirSync(path);
  return path;
}

interface RunResult {
  readonly status: number | null;
  readonly stdout: string;
  readonly stderr: string;
}

function runFilter(args: readonly string[], input = "", env: Record<string, string> = {}): RunResult {
  const result = spawnSync(process.execPath, [FILTER, ...args], {
    input,
    encoding: "utf8",
    env: { ...process.env, ...env },
  });
  return { status: result.status, stdout: result.stdout ?? "", stderr: result.stderr ?? "" };
}

describe("measured corpus", () => {
  for (const row of CORPUS_ROWS) {
    test(`${row.decision} ${row.rule}: ${row.command}`, () => {
      const verdict = decideDeletion(row.command, {
        settings: { unproven: row.unproven },
        redirect: row.redirect === "managed" ? managedResolver : plainResolver,
      });
      expect(verdict.decision).toBe(row.decision);
      expect(verdict.rule).toBe(row.rule);
      expect(verdict.reason.length).toBeGreaterThan(0);
    });
  }
});

// One verdict per case with an injected resolver, so nothing here reads the host.
function verdictOf(command: string, redirect: "managed" | "plain", unproven = "ask"): Verdict {
  return decideDeletion(command, {
    settings: { unproven },
    redirect: redirect === "managed" ? managedResolver : plainResolver,
  });
}

describe("command position", () => {
  test("a cmd argument is not the command word", () => {
    const verdict = verdictOf("echo cmd", "managed");
    expect(verdict.decision).toBe("allow");
    expect(verdict.rule).toBe("no-match");
  });

  test("a cmd command word denies", () => {
    const verdict = verdictOf("cmd /c del x", "managed");
    expect(verdict.decision).toBe("deny");
    expect(verdict.rule).toBe("cmd-shell");
  });

  test("a cmd behind a prefix is still the command word", () => {
    const verdict = verdictOf("xargs cmd /c del x", "managed");
    expect(verdict.decision).toBe("deny");
    expect(verdict.rule).toBe("cmd-shell");
  });

  test("a cmd argument inside an unquoted script stays an argument", () => {
    const verdict = verdictOf("pwsh -c x cmd y", "managed");
    expect(verdict.decision).toBe("allow");
    expect(verdict.rule).toBe("no-match");
  });

  test("a quoted -c script still reaches the cmd shell", () => {
    const verdict = verdictOf("pwsh -c 'cmd /c del x'", "managed");
    expect(verdict.decision).toBe("deny");
    expect(verdict.rule).toBe("cmd-shell");
  });

  test("a statement word does not hide the command word", () => {
    const verdict = verdictOf("then cmd /c del x", "managed");
    expect(verdict.decision).toBe("deny");
    expect(verdict.rule).toBe("cmd-shell");
  });

  test("a brace group does not hide the command word", () => {
    const verdict = verdictOf("{ cmd /c del x; }", "managed");
    expect(verdict.decision).toBe("deny");
    expect(verdict.rule).toBe("cmd-shell");
  });

  test("a negation does not hide the command word", () => {
    const verdict = verdictOf("! cmd /c del x", "managed");
    expect(verdict.decision).toBe("deny");
    expect(verdict.rule).toBe("cmd-shell");
  });

  test("a leading assignment does not hide the command word", () => {
    const verdict = verdictOf("FOO=1 cmd /c del x", "managed");
    expect(verdict.decision).toBe("deny");
    expect(verdict.rule).toBe("cmd-shell");
  });

  test("a leading assignment leaves the deletion word unproven", () => {
    const verdict = verdictOf("FOO=1 rm x", "plain");
    expect(verdict.decision).toBe("ask");
    expect(verdict.rule).toBe("unproven-redirect");
  });

  // A PATH assignment replaces the PATH the wrapper lives on, so the word can no
  // longer be proven by probing the filter's own PATH.
  test("a PATH assignment forces an unproven redirect", () => {
    for (const redirect of ["plain", "managed"] as const) {
      const verdict = verdictOf("PATH=/usr/bin rm x", redirect);
      expect(verdict.decision).toBe("ask");
      expect(verdict.rule).toBe("unproven-redirect");
    }
  });

  test("an escaped cmd command word denies", () => {
    const verdict = verdictOf("\\cmd /c del x", "managed");
    expect(verdict.decision).toBe("deny");
    expect(verdict.rule).toBe("cmd-shell");
  });
});

describe("escaped spelling", () => {
  test("an escaped word that resolves to the wrapper allows", () => {
    const verdict = verdictOf("\\rm x", "managed");
    expect(verdict.decision).toBe("allow");
    expect(verdict.rule).toBe("proven-redirect");
  });

  test("an escaped word with an unproven redirect asks", () => {
    const verdict = verdictOf("\\rm x", "plain");
    expect(verdict.decision).toBe("ask");
    expect(verdict.rule).toBe("unproven-redirect");
  });

  test("an escaped path is a native path", () => {
    const verdict = verdictOf("\\/bin/rm x", "managed");
    expect(verdict.decision).toBe("deny");
    expect(verdict.rule).toBe("native-path");
  });

  test("an escaped uppercase word still folds to a deletion", () => {
    const verdict = verdictOf("\\RM -rf x", "plain", "deny");
    expect(verdict.decision).toBe("deny");
    expect(verdict.rule).toBe("unproven-redirect");
  });
});

describe("find primitives", () => {
  test("-delete denies", () => {
    const verdict = verdictOf("find . -delete", "managed");
    expect(verdict.decision).toBe("deny");
    expect(verdict.rule).toBe("find-primitive");
  });

  test("-exec rm resolves like a command word", () => {
    const verdict = verdictOf("find . -exec rm {} \\;", "managed");
    expect(verdict.decision).toBe("allow");
    expect(verdict.rule).toBe("proven-redirect");
  });

  test("-exec rm with an unproven redirect asks", () => {
    const verdict = verdictOf("find . -exec rm {} \\;", "plain");
    expect(verdict.decision).toBe("ask");
    expect(verdict.rule).toBe("unproven-redirect");
  });

  test("-exec with a native path denies", () => {
    const verdict = verdictOf("find . -exec /bin/rm {} \\;", "managed");
    expect(verdict.decision).toBe("deny");
    expect(verdict.rule).toBe("native-path");
  });

  test("-exec with a quoted script recurses into it", () => {
    const verdict = verdictOf("find . -exec sh -c 'rm x' {} \\;", "managed");
    expect(verdict.decision).toBe("allow");
    expect(verdict.rule).toBe("proven-redirect");
  });

  test("-exec without a terminator takes the rest of the segment", () => {
    const verdict = verdictOf("find . -exec rm {}", "plain");
    expect(verdict.decision).toBe("ask");
    expect(verdict.rule).toBe("unproven-redirect");
  });

  test("-exec rip is not a deletion", () => {
    const verdict = verdictOf("find . -exec rip {} \\;", "managed");
    expect(verdict.decision).toBe("allow");
    expect(verdict.rule).toBe("no-match");
  });
});

describe("heredoc bodies", () => {
  const bodies = [
    "cat <<EOF\nrm -rf /\nEOF",
    "cat <<'EOF'\nrm -rf /\nEOF",
    'cat <<"EOF"\nrm -rf /\nEOF',
    "cat <<-EOF\n\trm -rf /\n\tEOF",
    "cat <<EOF\nrm -rf /",
  ];

  for (const command of bodies) {
    test(`the body is data, not a command: ${JSON.stringify(command)}`, () => {
      const verdict = verdictOf(command, "managed");
      expect(verdict.decision).toBe("allow");
      expect(verdict.rule).toBe("no-match");
    });
  }

  test("a command after the delimiter is still analyzed", () => {
    const verdict = verdictOf("cat <<EOF\nrm -rf /\nEOF\nrm -f /tmp/x", "managed");
    expect(verdict.decision).toBe("allow");
    expect(verdict.rule).toBe("proven-redirect");
  });

  test("a command after the delimiter follows settings.unproven", () => {
    const verdict = verdictOf("cat <<EOF\nrm -rf /\nEOF\nrm -f /tmp/x", "plain");
    expect(verdict.decision).toBe("ask");
    expect(verdict.rule).toBe("unproven-redirect");
  });

  // A comment runs to the newline, so an operator inside it opens no body and the
  // next line is still a command.
  test("a heredoc operator in a comment opens no body", () => {
    const managed = verdictOf("echo x # cat <<EOF\nrm -rf /\nEOF", "managed");
    expect(managed.decision).toBe("allow");
    expect(managed.rule).toBe("proven-redirect");
    const plain = verdictOf("echo x # cat <<EOF\nrm -rf /\nEOF", "plain");
    expect(plain.decision).toBe("ask");
    expect(plain.rule).toBe("unproven-redirect");
  });

  // `<<` inside $(( )) is a shift, so the expression is copied instead of read as
  // a redirection waiting for a body line.
  test("a shift in arithmetic opens no body", () => {
    const managed = verdictOf("echo $((1 << 2))\nrm -rf /", "managed");
    expect(managed.decision).toBe("allow");
    expect(managed.rule).toBe("proven-redirect");
    const plain = verdictOf("echo $((1 << 2))\nrm -rf /", "plain");
    expect(plain.decision).toBe("ask");
    expect(plain.rule).toBe("unproven-redirect");
  });

  // An arithmetic command is the same shift, at the start of a word.
  test("a shift in an arithmetic command opens no body", () => {
    const plain = verdictOf("(( x << 2 ))\nrm -rf /", "plain");
    expect(plain.decision).toBe("ask");
    expect(plain.rule).toBe("unproven-redirect");
  });

  // An unquoted delimiter leaves the body expandable, so a substitution in it
  // still runs and its command is live.
  test("a substitution in an unquoted body is still a command", () => {
    const plain = verdictOf("cat <<EOF\n$(rm -rf /)\nEOF", "plain");
    expect(plain.decision).toBe("ask");
    expect(plain.rule).toBe("unproven-redirect");
    const managed = verdictOf("cat <<EOF\n$(rm -rf /)\nEOF", "managed");
    expect(managed.decision).toBe("allow");
    expect(managed.rule).toBe("proven-redirect");
  });

  test("a quoted delimiter makes the body literal", () => {
    const verdict = verdictOf("cat <<'EOF'\n$(rm -rf /)\nEOF", "plain");
    expect(verdict.decision).toBe("allow");
    expect(verdict.rule).toBe("no-match");
  });

  test("an escaped delimiter makes the body literal", () => {
    const verdict = verdictOf("cat <<\\EOF\n$(rm -rf /)\nEOF", "plain");
    expect(verdict.decision).toBe("allow");
    expect(verdict.rule).toBe("no-match");
  });

  // A CRLF delimiter line still ends the body, so the next line is a command.
  test("a carriage return on the delimiter line ends the body", () => {
    const verdict = verdictOf("cat <<EOF\r\nrm -rf /\r\nEOF\r\nrm -f /tmp/x", "plain");
    expect(verdict.decision).toBe("ask");
    expect(verdict.rule).toBe("unproven-redirect");
  });

  test("two heredocs consume their bodies in order", () => {
    const verdict = verdictOf("cat <<A <<B\nx\nA\ny\nB", "managed");
    expect(verdict.decision).toBe("allow");
    expect(verdict.rule).toBe("no-match");
  });

  test("a command after the second body is still analyzed", () => {
    const managed = verdictOf("cat <<A <<B\nx\nA\ny\nB\nrm -f /tmp/x", "managed");
    expect(managed.decision).toBe("allow");
    expect(managed.rule).toBe("proven-redirect");
    const plain = verdictOf("cat <<A <<B\nx\nA\ny\nB\nrm -f /tmp/x", "plain");
    expect(plain.decision).toBe("ask");
    expect(plain.rule).toBe("unproven-redirect");
  });
});

describe("rip", () => {
  test("rip is not a deletion word", () => {
    const verdict = verdictOf("rip -rf x", "managed");
    expect(verdict.decision).toBe("allow");
    expect(verdict.rule).toBe("no-match");
  });
});

describe("settings.unproven", () => {
  test("an absent setting asks", () => {
    const verdict = decideDeletion("rm x", { settings: {}, redirect: plainResolver });
    expect(verdict.decision).toBe("ask");
    expect(verdict.rule).toBe("unproven-redirect");
  });

  test("a non-object settings value falls back to ask", () => {
    const verdict = decideDeletion("rm x", { settings: null, redirect: plainResolver });
    expect(verdict.decision).toBe("ask");
  });

  test("a null setting falls back to ask", () => {
    const verdict = decideDeletion("rm x", { settings: { unproven: null }, redirect: plainResolver });
    expect(verdict.decision).toBe("ask");
  });

  test("an unknown value denies and names every accepted word", () => {
    const verdict = decideDeletion("rm x", { settings: { unproven: "maybe" }, redirect: plainResolver });
    expect(verdict.decision).toBe("deny");
    expect(verdict.rule).toBe("unproven-redirect");
    for (const word of ["deny", "ask", "allow"]) expect(verdict.reason).toContain(word);
  });

  test("the setting is compared case-sensitively", () => {
    const verdict = decideDeletion("rm x", { settings: { unproven: "Allow" }, redirect: plainResolver });
    expect(verdict.decision).toBe("deny");
  });
});

describe("redirect proof", () => {
  test("a word that resolves to the home-manager wrapper is proven", () => {
    const { home, wrapperDir } = managedHome("rm");
    const resolver = managedRedirectResolver({ home, path: wrapperDir, platform: "darwin" });
    expect(resolver("rm")).toEqual({ proven: true, via: "wrapper", path: join(wrapperDir, "rm") });
  });

  test("a plain deletion binary ahead of the wrapper is unproven", () => {
    const { home, wrapperDir } = managedHome("rm");
    const plainBin = join(home, "plain-bin");
    mkdirSync(plainBin);
    writeExecutable(join(plainBin, "rm"));
    const resolver = managedRedirectResolver({ home, path: `${plainBin}:${wrapperDir}`, platform: "darwin" });
    const proof = resolver("rm");
    expect(proof.proven).toBe(false);
    if (!proof.proven) expect(proof.why).toContain("not the managed safe-delete wrapper");
  });

  test("a plain file at the wrapper path is unproven", () => {
    const home = fixtureHome();
    const wrapperDir = join(home, ".local", "bin");
    mkdirSync(wrapperDir, { recursive: true });
    writeExecutable(join(wrapperDir, "rm"));
    const resolver = managedRedirectResolver({ home, path: wrapperDir, platform: "darwin" });
    const proof = resolver("rm");
    expect(proof.proven).toBe(false);
    if (!proof.proven) expect(proof.why).toContain("plain file rather than the managed symlink");
  });

  test("a wrapper symlinked to something else is unproven", () => {
    const home = fixtureHome();
    const wrapperDir = join(home, ".local", "bin");
    mkdirSync(wrapperDir, { recursive: true });
    writeExecutable(join(home, "plain-rm"));
    symlinkSync(join(home, "plain-rm"), join(wrapperDir, "rm"));
    const resolver = managedRedirectResolver({ home, path: wrapperDir, platform: "darwin" });
    const proof = resolver("rm");
    expect(proof.proven).toBe(false);
    if (!proof.proven) expect(proof.why).toContain("not the home-manager wrapper");
  });

  test("a word absent from PATH is unproven", () => {
    const home = fixtureHome();
    const resolver = managedRedirectResolver({ home, path: emptyPath(home), platform: "darwin" });
    const proof = resolver("rm");
    expect(proof.proven).toBe(false);
    if (!proof.proven) expect(proof.why).toContain("does not resolve on PATH");
  });

  test("an unknown home is unproven", () => {
    const home = fixtureHome();
    const proof = managedRedirectResolver({ home: null, path: emptyPath(home), platform: "darwin" })("rm");
    expect(proof.proven).toBe(false);
    if (!proof.proven) expect(proof.why).toContain("HOME is unset");
  });

  test("Windows needs the shim manifest to prove a redirect", () => {
    const home = fixtureHome();
    const bin = join(home, "win-bin");
    mkdirSync(bin);
    writeFileSync(join(bin, "rm.exe"), "rip.exe fixture bytes\n");
    const proof = managedRedirectResolver({
      home,
      path: bin,
      platform: "win32",
      pathext: ".exe",
      manifest: join(home, "absent-shims.json"),
    })("rm");
    expect(proof.proven).toBe(false);
    if (!proof.proven) expect(proof.why).toContain("missing");
  });

  test("the policy follows the proof it is handed", () => {
    const proven = decideDeletion("rm x", { settings: { unproven: "deny" }, redirect: managedResolver });
    expect(proven.rule).toBe("proven-redirect");
    expect(proven.decision).toBe("allow");
    const unproven = decideDeletion("rm x", { settings: { unproven: "deny" }, redirect: plainResolver });
    expect(unproven.rule).toBe("unproven-redirect");
    expect(unproven.decision).toBe("deny");
  });

  test("a prefix that overrides PATH reaches the -c script it starts", () => {
    const verdict = decideDeletion('env PATH=/usr/bin sh -c "rm x"', {
      settings: { unproven: "ask" },
      redirect: managedResolver,
    });
    expect(verdict.rule).toBe("unproven-redirect");
    expect(verdict.decision).toBe("ask");
  });
});

// A Windows fixture: a deployed shim directory, the bytes the manifest hashes,
// and a manifest path under a temp USER root. The resolver is injected with this
// probe, so no case reads the host's LOCALAPPDATA, home directory, or PATH.
interface Win32Fixture {
  readonly bin: string;
  readonly manifest: string;
  readonly ripHash: string;
}

const RIP_BYTES = "rip.exe fixture bytes\n";

function win32Fixture(): Win32Fixture {
  const root = mkdtempSync(join(tmpdir(), "safe-delete-win32-"));
  const bin = join(root, "bin");
  const stateDir = join(root, "state", "safe-delete");
  mkdirSync(bin, { recursive: true });
  mkdirSync(stateDir, { recursive: true });
  writeFileSync(join(bin, "rm.exe"), RIP_BYTES);
  writeFileSync(join(bin, "del.exe"), RIP_BYTES);
  return {
    bin,
    manifest: join(stateDir, "shims.json"),
    ripHash: createHash("sha256").update(RIP_BYTES).digest("hex"),
  };
}

function writeShimManifest(fixture: Win32Fixture, shims: readonly { name: string; path: string }[]): void {
  writeFileSync(
    fixture.manifest,
    `${JSON.stringify({ version: 1, ripHash: fixture.ripHash, shims }, null, 0)}\n`,
  );
}

function win32Verdict(command: string, fixture: Win32Fixture, overrides: Partial<RedirectProbe> = {}): Verdict {
  const probe: RedirectProbe = {
    home: fixture.bin,
    path: fixture.bin,
    platform: "win32",
    manifest: fixture.manifest,
    pathext: ".exe",
    powershell: "profile",
    noProfile: hasNoProfile(command),
    ...overrides,
  };
  return decideDeletion(command, {
    platform: "win32",
    settings: { unproven: "ask" },
    redirect: managedRedirectResolver(probe),
  });
}

describe("Windows proof", () => {
  test("a shim the manifest lists with rip.exe's hash allows", () => {
    const fixture = win32Fixture();
    writeShimManifest(fixture, [{ name: "rm.exe", path: join(fixture.bin, "rm.exe") }]);
    const verdict = win32Verdict("rm x", fixture);
    expect(verdict.decision).toBe("allow");
    expect(verdict.rule).toBe("proven-redirect");
    expect(verdict.reason).toContain("rip shim");
  });

  test("an extension-qualified word resolves like the bare word", () => {
    const fixture = win32Fixture();
    writeShimManifest(fixture, [{ name: "rm.exe", path: join(fixture.bin, "rm.exe") }]);
    const verdict = win32Verdict("rm.exe x", fixture);
    expect(verdict.decision).toBe("allow");
    expect(verdict.rule).toBe("proven-redirect");
  });

  test("a shim whose bytes changed is unproven", () => {
    const fixture = win32Fixture();
    writeShimManifest(fixture, [{ name: "rm.exe", path: join(fixture.bin, "rm.exe") }]);
    writeFileSync(join(fixture.bin, "rm.exe"), `${RIP_BYTES}tampered`);
    const verdict = win32Verdict("rm x", fixture);
    expect(verdict.decision).toBe("ask");
    expect(verdict.rule).toBe("unproven-redirect");
    expect(verdict.reason).toContain("hash");
  });

  test("a resolved file the manifest does not list is unproven", () => {
    const fixture = win32Fixture();
    writeShimManifest(fixture, []);
    const verdict = win32Verdict("rm x", fixture);
    expect(verdict.decision).toBe("ask");
    expect(verdict.rule).toBe("unproven-redirect");
    expect(verdict.reason).toContain("does not list");
  });

  test("a Windows native path denies", () => {
    const fixture = win32Fixture();
    for (const command of ["C:\\Windows\\System32\\rm.exe x", "C:/Windows/System32/RM.exe x"]) {
      const verdict = win32Verdict(command, fixture);
      expect(verdict.decision).toBe("deny");
      expect(verdict.rule).toBe("native-path");
    }
  });

  test("a manifest-listed shim proves del when the profile assumption is off", () => {
    const fixture = win32Fixture();
    writeShimManifest(fixture, [{ name: "del.exe", path: join(fixture.bin, "del.exe") }]);
    const verdict = win32Verdict("del x", fixture, { powershell: "none" });
    expect(verdict.decision).toBe("allow");
    expect(verdict.rule).toBe("proven-redirect");
    expect(verdict.reason).toContain("rip shim");
  });

  test("-nop leaves even a shim word unproven", () => {
    const fixture = win32Fixture();
    writeShimManifest(fixture, [{ name: "rm.exe", path: join(fixture.bin, "rm.exe") }]);
    const plain = win32Verdict('pwsh -c "rm x"', fixture);
    expect(plain.decision).toBe("allow");
    const noProfile = win32Verdict('pwsh -nop -c "rm x"', fixture);
    expect(noProfile.decision).toBe("ask");
    expect(noProfile.rule).toBe("unproven-redirect");
  });
});

describe("PowerShell profile proof", () => {
  test("the managed profile proves a deletion word it overrides", () => {
    const verdict = decideDeletion("Remove-Item x", { platform: "win32", settings: {} });
    expect(verdict.decision).toBe("allow");
    expect(verdict.rule).toBe("proven-redirect");
    expect(verdict.reason).toContain("managed PowerShell profile");
  });

  test("settings.powershell none leaves a word with no shim unproven", () => {
    const verdict = decideDeletion("Remove-Item x", { platform: "win32", settings: { powershell: "none" } });
    expect(verdict.decision).toBe("ask");
    expect(verdict.rule).toBe("unproven-redirect");
  });

  test("a POSIX platform gets no profile proof", () => {
    const home = fixtureHome();
    const verdict = decideDeletion("Remove-Item x", {
      platform: "darwin",
      settings: { unproven: "deny" },
      redirect: managedRedirectResolver({
        home,
        path: emptyPath(home),
        platform: "darwin",
        powershell: "profile",
      }),
    });
    expect(verdict.decision).toBe("deny");
    expect(verdict.rule).toBe("unproven-redirect");
  });

  test("-NoProfile leaves that word unproven", () => {
    const verdict = decideDeletion('pwsh -NoProfile -c "Remove-Item x"', { platform: "win32", settings: {} });
    expect(verdict.decision).toBe("ask");
    expect(verdict.rule).toBe("unproven-redirect");
    expect(verdict.reason).toContain("NoProfile");
  });
});

describe("filter mode", () => {
  test("prints exactly one three-field verdict line", () => {
    const result = runFilter(["--settings", "{}", "--command", "rm x"]);
    expect(result.status).toBe(0);
    expect(result.stdout.endsWith("\n")).toBe(true);
    const lines = result.stdout.trimEnd().split("\n");
    expect(lines).toHaveLength(1);
    const fields = lines[0]!.split("\t");
    expect(fields).toHaveLength(3);
    expect(["allow", "ask", "deny"]).toContain(fields[0]!);
    expect([
      "native-path",
      "cmd-shell",
      "find-primitive",
      "proven-redirect",
      "unproven-redirect",
      "no-match",
    ]).toContain(fields[1]!);
    expect(fields[2]!.length).toBeGreaterThan(0);
  });

  test("invalid settings answer filter-error and exit 0", () => {
    const result = runFilter(["--settings", "{not json", "--command", "rm x"]);
    expect(result.status).toBe(0);
    const [decision, rule] = result.stdout.trimEnd().split("\t");
    expect(decision).toBe("ask");
    expect(rule).toBe("filter-error");
  });

  test("an unknown argument answers filter-error", () => {
    const result = runFilter(["--nope"]);
    expect(result.status).toBe(0);
    const [decision, rule] = result.stdout.trimEnd().split("\t");
    expect(decision).toBe("ask");
    expect(rule).toBe("filter-error");
  });
});

describe("hook mode", () => {
  test("a native path is denied on stderr with exit 2", () => {
    const result = runFilter(["--hook"], JSON.stringify({ command: "/bin/rm x" }));
    expect(result.status).toBe(2);
    expect(result.stderr).toContain("BLOCKED: native rm");
    expect(result.stdout).toBe("");
  });

  test("the command is read from a tool_input payload", () => {
    const result = runFilter(["--hook"], JSON.stringify({ tool_input: { command: "/bin/rm x" } }));
    expect(result.status).toBe(2);
    expect(result.stderr).toContain("BLOCKED: native rm");
  });

  test("a clean command exits 0 with no output", () => {
    const result = runFilter(["--hook"], JSON.stringify({ command: "ls -la" }));
    expect(result.status).toBe(0);
    expect(result.stdout).toBe("");
    expect(result.stderr).toBe("");
  });

  test("an unproven deletion exits 0 under the default ask", () => {
    const home = fixtureHome();
    const result = runFilter(["--hook"], JSON.stringify({ command: "rm x" }), {
      HOME: home,
      PATH: emptyPath(home),
    });
    expect(result.status).toBe(0);
    expect(result.stderr).toBe("");
  });

  test("an unproven deletion exits 2 when settings deny it", () => {
    const home = fixtureHome();
    const result = runFilter(
      ["--hook", "--settings", JSON.stringify({ unproven: "deny" })],
      JSON.stringify({ command: "rm x" }),
      { HOME: home, PATH: emptyPath(home) },
    );
    expect(result.status).toBe(2);
    expect(result.stderr).toContain("BLOCKED: deletion command: rm does not resolve on PATH");
  });

  test("a payload without a command exits 0", () => {
    const result = runFilter(["--hook"], "{}");
    expect(result.status).toBe(0);
    expect(result.stdout).toBe("");
    expect(result.stderr).toBe("");
  });
});
