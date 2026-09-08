---
description: "Use when adding, updating, or reviewing AI model selections in src/modules/ai/models.json, VS Code chatLanguageModels host files, scripts/ai-sync.sh, src/platforms/Windows/modules/Invoke-AISync.ps1, or src/modules/ai/default.nix."
name: "AI Model Selection"
applyTo: "src/modules/ai.nix, src/modules/configs/ollama/**, src/modules/configs/litellm/**, src/users/*/vscode/chatLanguageModels.*.json, src/hosts/*/ai.nix, scripts/ai-sync.sh, scripts/ai-sync.ps1, src/platforms/Windows/modules/system/Invoke-AISync.ps1, src/platforms/Windows/modules/system/Sync-LiteLLMService.ps1"
---

# AI Model Selection

## Profile key convention

`src/modules/ai/models.json` keys by **host name** (PascalCase, matching `networking.hostName` / `ComputerName`):

| Key | Host | Resolved by |
| --- | --- | --- |
| `MacBook` | macOS | `ai-sync.sh` Darwin branch |
| `NixOS` | NixOS | `ai-sync.sh` wildcard branch |
| `Windows` | Windows | `Invoke-AISync.ps1` |

Exact hostname only — no lowercase, no generic names. New hosts: update detection in both `ai-sync.sh` and `Invoke-AISync.ps1`.

## Hardware constraints

| Host | Budget | Notes |
| --- | --- | --- |
| `MacBook` | ≤ 16 GB GPU (~17–18 GB OK) | 24 GB unified RAM; Metal; flash attention + q4_0 KV cache |
| `NixOS` | ≤ 6 GB VRAM (model ≤ ~5 GB) | `services.ollama.acceleration = "cuda"`; `MemoryMax = "16G"` |
| `Windows` | ≤ 6 GB VRAM | Same as NixOS |

## Cross-file sync

Update in the same change: `src/modules/ai/models.json`, `src/users/default/vscode/chatLanguageModels.{MacBook,NixOS,Windows}.json`, and the manifest comment in `src/modules/ai/default.nix`. Each host's `chatLanguageModels` IDs must be a subset of the host key in `models.json`. No stale entries.

## Quantization

Tags: `<base>-<quant>`. No q3 or lower GGUF variants exist in Ollama.

| Suffix | Size vs Q4_K_M | Quality | When |
| --- | --- | --- | --- |
| `q4_K_M` | baseline | baseline | Default |
| `q8_0` | ~1.7× | better | MacBook only when headroom allows |
| `fp16`/`bf16` | ~2× | near-lossless | MacBook small models only |
| `it-qat` | same as Q4_K_M | approaches BF16 | Gemma models (gemma3, gemma4) |
| `nvfp4` | slightly smaller | similar | NVIDIA GPU only |
| `mxfp8` | ~1.5× | good | NVIDIA GPU or Apple MLX |
| `mlx-bf16` | ~2× | near-lossless | Apple MLX; MacBook with headroom |

**Preference**: larger param count > better quantization. 27B `q4_K_M` > 14B `q8_0`. **MacBook**: `q4_K_M` default; `it-qat` when available; `e4b-it-bf16` for `gemma4:e4b`. **NixOS/Windows**: `q4_K_M` only. Metadata in `src/modules/ai/models.json` + `src/modules/ai/default.nix` — do not duplicate.

## Tool-calling verification

Before committing a model change relying on tool calling:

1. Start Ollama with the new model.
2. Run function-call curl test (example in `default.nix` comment block).
3. Record in `default.nix`: `— tool-calling curl-tested on <host>: PASS` or `FAIL`.
4. Do not deploy until tool calling passes on that host.
