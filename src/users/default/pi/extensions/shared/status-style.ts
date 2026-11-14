/**
 * Tone helper shared by the pi status extensions. `setStatus` accepts one plain
 * string, so a warning or error tone rides on an SGR prefix: both the built-in
 * footer and `pi-powerline-footer` strip only trailing SGR, which keeps a
 * leading code visible. Color is suppressed when `NO_COLOR` is present (even
 * empty) or `TERM` is `dumb`, following the no-color convention.
 */

export type StatusTone = "warning" | "error";

const ESC = String.fromCharCode(27);
const RESET = `${ESC}[0m`;

const TONE_PREFIX: Record<StatusTone, string> = {
	warning: `${ESC}[33m`,
	error: `${ESC}[31m`,
};

export function statusText(
	text: string,
	tone: StatusTone,
	env: NodeJS.ProcessEnv = process.env,
): string {
	if (Object.prototype.hasOwnProperty.call(env, "NO_COLOR") || env.TERM === "dumb") {
		return text;
	}
	return `${TONE_PREFIX[tone]}${text}${RESET}`;
}
