---
description: "Use always: reduce token usage and Copilot cost via response language, research scope, terminal output hygiene, and subagent delegation rules."
name: "Cost Efficiency"
applyTo: "**"
---

Rules to reduce token waste and Copilot cost. Grounded in analysis of actual usage patterns.

- **Respond in English only.** Never output in another language unless the user explicitly requests it. Prevents wasted re-query turns (user asks for English redo of an already-generated response).
- **Research scope: brief findings, not full reports.** For queries scoped with "research only", "verify only", or similar boundary markers, produce concise findings (≤~1k chars). Give the key answer and let the user ask for depth. Do not generate comprehensive reports that will be discarded or refined.
- **Discard terminal output after use.** After acting on terminal output, summarize the exit code and relevant result in your own words. Do not carry raw terminal output into the next turn's context. Accumulated terminal noise is the single largest input-token waste in multi-turn sessions.
- **Delegate exploration to subagents.** When the user asks a broad exploratory question or says "research only", use `runSubagent` with agentName `"Explore"` as the default approach. The subagent does the file reading and reasoning in its own context; you get a compact summary. Only read files directly when the question is narrow (one or two files). This is a hard rule, not a suggestion.
