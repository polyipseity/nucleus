import { afterEach, describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { statusText } from "../../../../../src/users/default/pi/extensions/shared/status-style.ts";

const ESC = String.fromCharCode(27);
const SOURCE_PATH = join(
	import.meta.dir,
	"../../../../../src/users/default/pi/extensions/shared/status-style.ts",
);

const originalNoColor = process.env.NO_COLOR;
const originalTerm = process.env.TERM;

afterEach(() => {
	if (originalNoColor === undefined) {
		delete process.env.NO_COLOR;
	} else {
		process.env.NO_COLOR = originalNoColor;
	}
	if (originalTerm === undefined) {
		delete process.env.TERM;
	} else {
		process.env.TERM = originalTerm;
	}
});

describe("statusText", () => {
	test("returns the text unchanged when NO_COLOR is present, including an empty value", () => {
		expect(statusText("sandbox: none", "warning", { NO_COLOR: "" })).toBe("sandbox: none");
		expect(statusText("sandbox: none", "warning", { NO_COLOR: "1" })).toBe("sandbox: none");
		expect(statusText("safe-delete: blocked", "error", { NO_COLOR: "" })).toBe("safe-delete: blocked");
	});

	test("returns the text unchanged when TERM is dumb", () => {
		expect(statusText("sandbox: none", "warning", { TERM: "dumb" })).toBe("sandbox: none");
		expect(statusText("safe-delete: blocked", "error", { TERM: "dumb" })).toBe("safe-delete: blocked");
	});

	test("wraps a warning in yellow SGR", () => {
		expect(statusText("sandbox: none", "warning", {})).toBe(`${ESC}[33msandbox: none${ESC}[0m`);
	});

	test("wraps an error in red SGR", () => {
		expect(statusText("safe-delete: blocked", "error", {})).toBe(
			`${ESC}[31msafe-delete: blocked${ESC}[0m`,
		);
	});

	test("colors when TERM is anything other than dumb", () => {
		expect(statusText("sandbox: none", "warning", { TERM: "xterm-256color" })).toBe(
			`${ESC}[33msandbox: none${ESC}[0m`,
		);
	});

	test("defaults to process.env", () => {
		process.env.NO_COLOR = "";
		delete process.env.TERM;
		expect(statusText("sandbox: none", "warning")).toBe("sandbox: none");

		delete process.env.NO_COLOR;
		process.env.TERM = "dumb";
		expect(statusText("sandbox: none", "warning")).toBe("sandbox: none");

		delete process.env.TERM;
		expect(statusText("sandbox: none", "warning")).toBe(`${ESC}[33msandbox: none${ESC}[0m`);
	});

	test("source builds the escape with String.fromCharCode(27) and carries no raw ESC byte", () => {
		const source = readFileSync(SOURCE_PATH, "utf8");
		expect(source).toContain("String.fromCharCode(27)");
		expect(source).not.toContain("\\x1b");
		expect(source).not.toContain("\\u001b");
		expect(source).not.toContain(String.fromCharCode(27));
	});
});
