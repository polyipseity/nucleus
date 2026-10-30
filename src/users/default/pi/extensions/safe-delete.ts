/**
 * Safe Delete Extension for Pi
 *
 * Blocks dangerous deletion commands (rm, del, rd, rmdir, erase, ri, unlink,
 * shred, Remove-Item, native /bin/rm, cmd.exe) and suggests safe alternatives
 * (shell-safe-rm, rip2/rip). Strips quoted strings first to avoid false
 * positives, whitelists CLI subcommands that use 'rm' as a verb, and
 * distinguishes PATH shims/aliases from native deletion binaries.
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

// CLI subcommands that use 'rm' as a verb (not file deletion).
const CLI_RM_WHITELIST = [
	/\bgit\s+rm\b/,
	/\bvercel\s+env\s+rm\b/,
	/\bbrew\s+rm\b/,
	/\bcargo\s+rm\b/,
	/\bnpm\s+rm\b/,
	/\bpip\s+rm\b/,
	/\byarn\s+remove\b/,
];

// Deletion commands across all hosts (union of POSIX + Windows).
const DELETE_COMMANDS = "rm|del|rd|rmdir|erase|ri|unlink|shred|Remove-Item";

// Hard block: native rm paths, backslash escapes, subshells, remote execution.
const HARD_BLOCK_PATTERNS = [
	// Absolute/relative paths to rm.
	/(?:^|&&|\|\||;|\||\$\(|`)\s*\/[\w./]*\/rm\b/,
	/(?:^|&&|\|\||;|\||\$\(|`)\s*\.\/rm\b/,
	// Backslash escape bypasses aliases (any deletion command).
	new RegExp(`(?:^|&&|\\|\\||;|\\||\\$\\(|\`)\\s*\\\\(?:${DELETE_COMMANDS.replace(/\|/g, "|")})\\b`),
	// Subshell/remote wrapping.
	/\b(?:sh|bash|zsh|dash)\s+-c\s+.*\brm\b/,
	/\b(?:ssh|docker\s+exec|kubectl\s+exec)\b.*\brm\b/,
	// find with delete.
	/\bfind\b.*\s-delete\b/,
	/\bfind\b.*-exec\s+rm\b/,
	// Catastrophic targets.
	/\brm\b.*\s+\/\s*$/,
	/\brm\b.*\s+~\/?\s*$/,
	/\brm\b.*\s+\/\*\s*$/,
];

// Ask: plain deletion commands with dangerous flags or targets.
const ASK_PATTERNS = [
	/\brm\s+(-[a-zA-Z]*r[a-zA-Z]*|-r|--recursive)/i,
	/\brm\s+(-[a-zA-Z]*f[a-zA-Z]*|-f|--force)/i,
	new RegExp(`\\b(?:${DELETE_COMMANDS})\\b`),
	/\bsudo\s+rm\b/,
];

function stripQuotes(command: string): string {
	let stripped = command.replace(/"(?:[^"\\]|\\.)*"/g, '""');
	stripped = stripped.replace(/'[^']*'/g, "''");
	return stripped;
}

export default function (pi: ExtensionAPI) {
	pi.on("tool_call", async (event, ctx) => {
		if (event.toolName !== "bash") return undefined;

		const command = event.input.command as string;
		const stripped = stripQuotes(command);

		// Whitelist: CLI subcommands using 'rm' as verb.
		if (CLI_RM_WHITELIST.some((p) => p.test(stripped))) {
			return undefined;
		}

		// Hard block: native rm paths, escapes, subshells, remote.
		if (HARD_BLOCK_PATTERNS.some((p) => p.test(stripped))) {
			if (!ctx.hasUI) {
				return { block: true, reason: "Dangerous command blocked (no UI). Use shell-safe-rm or rip2/rip instead." };
			}
			// Even with UI, hard block these (no override).
			return { block: true, reason: "BLOCKED: Native or bypassed deletion command detected. Use shell-safe-rm or rip2/rip instead." };
		}

		// Check if any deletion command appears as an actual command (not in quotes).
		const hasDeleteCommand = new RegExp(`(?:^|&&|\\|\\||;|\\||\\$\\(|\`)\\s*(?:${DELETE_COMMANDS})\\b`).test(stripped) ||
			/\bsudo\s+rm\b/.test(stripped) ||
			/\bxargs\s+rm\b/.test(stripped);

		if (!hasDeleteCommand) {
			// Deletion command only appeared inside quotes or not at all — allow.
			return undefined;
		}

		// Ask: dangerous deletion patterns.
		const needsAsk = ASK_PATTERNS.some((p) => p.test(stripped));
		if (needsAsk) {
			if (!ctx.hasUI) {
				return { block: true, reason: "Dangerous deletion command blocked (no UI for confirmation). Use shell-safe-rm or rip2/rip instead." };
			}
			const choice = await ctx.ui.select(`⚠️ Potentially dangerous command:\n\n  ${command}\n\nAllow?`, ["Allow", "Block"]);
			if (choice !== "Allow") {
				return { block: true, reason: "Blocked by safe-delete extension" };
			}
		}

		return undefined;
	});
}
