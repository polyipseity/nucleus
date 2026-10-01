---
description: "Use when adding, updating, or reviewing AI model selections in src/modules/configs/ollama/models.json, VS Code chatLanguageModels host files, scripts/ai.sh, or src/platforms/Windows/modules/system/Invoke-AISync.ps1."
name: "AI Model Selection"
applyTo: "scripts/ai.sh, src/modules/ai.nix, src/modules/configs/ollama/**, src/modules/configs/litellm/**, src/users/*/vscode/chatLanguageModels.*.json, src/hosts/*/ai.nix, src/platforms/Windows/modules/system/Invoke-AISync.ps1, src/platforms/Windows/modules/system/Sync-LiteLLMService.ps1"
---

# AI model selection

## Profile keys

`src/modules/configs/ollama/models.json` keys by host name in PascalCase, matching `networking.hostName` and `ComputerName`: `MacBook`, `NixOS`, `Windows`. No lowercase or generic names; a new host also needs detection in `Invoke-AISync.ps1`.

## Hardware budgets

| Host | Budget | Notes |
| --- | --- | --- |
| `MacBook` | ≤ 16 GB GPU (~17-18 GB OK) | 24 GB unified RAM; Metal; flash attention + q4_0 KV cache |
| `NixOS` | ≤ 6 GB VRAM (model ≤ ~5 GB) | `services.ollama.acceleration = "cuda"`; `MemoryMax = "16G"` |
| `Windows` | ≤ 6 GB VRAM | same as NixOS |

## Cross-file sync

One change updates `src/modules/configs/ollama/models.json` and `src/users/default/vscode/chatLanguageModels.{MacBook,NixOS,Windows}.json`. Each host's `chatLanguageModels` IDs must be a subset of that host's key in `models.json`, with no stale entries.

## Quantization

Tags are `<base>-<quant>`. No q3 or lower GGUF variants exist in Ollama.

| Suffix | Size vs Q4_K_M | Quality | When |
| --- | --- | --- | --- |
| `q4_K_M` | baseline | baseline | default |
| `q8_0` | ~1.7x | better | MacBook with headroom |
| `fp16`/`bf16` | ~2x | near-lossless | MacBook small models |
| `it-qat` | same as Q4_K_M | approaches BF16 | Gemma models (gemma3, gemma4) |
| `nvfp4` | slightly smaller | similar | NVIDIA GPU only |
| `mxfp8` | ~1.5x | good | NVIDIA GPU or Apple MLX |
| `mlx-bf16` | ~2x | near-lossless | Apple MLX; MacBook with headroom |

Larger param count beats better quantization: 27B `q4_K_M` over 14B `q8_0`. MacBook takes `q4_K_M` by default, `it-qat` when available, and `e4b-it-bf16` for `gemma4:e4b`. NixOS and Windows take `q4_K_M` only.

## Tool-calling verification

A model change that relies on tool calling is not ready to deploy until a function-call curl test against the running model passes on that host. Start Ollama with the model, run the test, and record `tool-calling curl-tested on <host>: PASS` or `FAIL` in the change's commit message. The rule has no file to record it in, so no comment block gets added for it.
