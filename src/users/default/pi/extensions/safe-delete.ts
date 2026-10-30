/**
 * Safe Delete Extension for Pi
 *
 * Blocks dangerous deletion commands (rm, cmd.exe, /bin/rm) and suggests
 * safe alternatives (shell-safe-rm, rip2/rip).
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

export default function (pi: ExtensionAPI) {
	const dangerousPatterns = [
		/\brm\b/i,
		/\bcmd\.exe\b/i,
		/\bcmd\b/i,
		/\/bin\/rm\b/i,
	];

	pi.on("tool_call", async (event, ctx) => {
		if (event.toolName !== "bash") return undefined;

		const command = event.input.command as string;
		const isDangerous = dangerousPatterns.some((p) => p.test(command));

		if (isDangerous) {
			if (!ctx.hasUI) {
				return { block: true, reason: "Dangerous command blocked (no UI for confirmation). Use shell-safe-rm or rip2/rip instead." };
			}

			const choice = await ctx.ui.select(`⚠️ Potentially dangerous command:\n\n  ${command}\n\nBlock?`, ["Block", "Allow"]);

			if (choice === "Block") {
				return { block: true, reason: "Blocked by safe-delete extension" };
			}
		}

		return undefined;
	});
}
