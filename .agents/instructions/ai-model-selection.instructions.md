---
description: "Use when adding or reviewing AI model selections in Ollama, VS Code chatLanguageModels, or AI sync scripts."
name: "AI Model Selection"
applyTo: "scripts/ai.sh, src/modules/ai.nix, src/modules/configs/ollama/**, src/modules/configs/litellm/**, src/users/*/vscode/chatLanguageModels.*.json, src/hosts/*/ai.nix, src/platforms/Windows/modules/system/Invoke-AISync.ps1, src/platforms/Windows/modules/system/Sync-LiteLLMService.ps1"
---

# AI model selection

`src/modules/configs/ollama/models.json` keys by PascalCase host (`MacBook`, `NixOS`, `Windows`), matching `networking.hostName` and `ComputerName`; a new host also needs `Invoke-AISync.ps1` detection. Budgets: MacBook ≤16 GB GPU (~17-18 GB OK, 24 GB unified, Metal), NixOS ≤6 GB VRAM (model ≤~5 GB, CUDA, `MemoryMax = "16G"`), Windows ≤6 GB VRAM.

One change updates `models.json` and `src/users/default/vscode/chatLanguageModels.{MacBook,NixOS,Windows}.json`; each host's IDs must be a subset with no stale entries. Tags are `<base>-<quant>`; no q3 or lower. Default `q4_K_M`, `q8_0` ~1.7x, `fp16`/`bf16` ~2x, `it-qat` for Gemma, `nvfp4` NVIDIA only, `mxfp8` ~1.5x, `mlx-bf16` for Apple MLX. Larger parameter count beats better quantization; NixOS and Windows use `q4_K_M` only.

A tool-calling model is not deployable until a function-call curl test passes on that host; record `tool-calling curl-tested on <host>: PASS` or `FAIL` in the commit message. Details: `.agents/skills/nucleus-platform-reference/references/ai-model-selection.md`.
