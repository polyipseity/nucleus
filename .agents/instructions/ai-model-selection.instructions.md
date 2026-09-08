---
description: "Use when adding, updating, or reviewing AI model selections in src/modules/ai/models.json, VS Code chatLanguageModels host files, scripts/ai-sync.sh, src/platforms/Windows/modules/Invoke-AISync.ps1, or src/modules/ai/default.nix."
name: "AI Model Selection"
applyTo: "src/modules/ai/**, src/users/*/vscode/chatLanguageModels.*.json, src/hosts/*/ai.nix, scripts/ai-sync.sh, scripts/ai-sync.ps1, src/platforms/Windows/modules/system/Invoke-AISync.ps1, src/platforms/Windows/modules/system/Sync-LiteLLMService.ps1, src/modules/ai/litellm-config.yml"
---

# AI Model Selection

## Profile key convention

`src/modules/ai/models.json` keys by **host name** (PascalCase, matching `networking.hostName` / `ComputerName`):

| Key | Host | Resolved by |
| --- | --- | --- |
| `MacBook` | macOS | `ai-sync.sh` Darwin branch |
| `NixOS` | NixOS | `ai-sync.sh` wildcard branch |
| `Windows` | Windows | `Invoke-AISync.ps1` |

Exact OS hostname only — no lowercase, no generic names (`"mac"`, `"pc"`). New hosts: add key + update detection in both `ai-sync.sh` and `Invoke-AISync.ps1`.

## Hardware constraints

| Host | Memory budget | Notes |
| --- | --- | --- |
| `MacBook` | ≤ 16 GB GPU (slight excess ~17–18 GB OK) | 24 GB unified RAM; Apple Silicon Metal; flash attention + q4_0 KV cache |
| `NixOS` | ≤ 6 GB VRAM (model ≤ ~5 GB) | `services.ollama.acceleration = "cuda"`; `MemoryMax = "16G"` |
| `Windows` | ≤ 6 GB VRAM | Same class as NixOS |

## Cross-file sync

Update all in the same change:

1. `src/modules/ai/models.json` host model lists.
2. `src/users/default/vscode/chatLanguageModels.{MacBook,NixOS,Windows}.json`
3. Manifest comment in `src/modules/ai/default.nix`.

Each host's `chatLanguageModels.<host>.json` IDs must be a subset of the host key in `models.json`. No stale entries.

## Quantization

Tags: `<base>-<quant>`.

| Suffix | Size vs Q4_K_M | Quality | When |
| --- | --- | --- | --- |
| `q4_K_M` | baseline | baseline | Default; best quality/size |
| `q8_0` | ~1.7× | better | MacBook only when headroom allows |
| `fp16`/`bf16` | ~2× | near-lossless | MacBook small models only (e.g. e4b) |
| `it-qat` | same as Q4_K_M | approaches BF16 | Gemma models shipping QAT (gemma3, gemma4) |
| `nvfp4` | slightly smaller | similar | NVIDIA GPU only |
| `mxfp8` | ~1.5× | good | NVIDIA GPU or Apple MLX |
| `mlx-bf16` | ~2× | near-lossless | Apple MLX; MacBook with headroom |

**Preference**: larger param count beats better quantization. 27B `q4_K_M` over 14B `q8_0` even at similar sizes. No q3 or lower GGUF variants exist in Ollama.

- **MacBook**: `q4_K_M` default; `it-qat` when available. `e4b-it-bf16` (16 GB) for `gemma4:e4b` when max quality desired.
- **NixOS/Windows**: `q4_K_M` only — VRAM is tight.

Sizes and metadata in `src/modules/ai/models.json` + `src/modules/ai/default.nix`. Do not duplicate.

## Tool-calling verification

Before committing a model change relying on tool calling:

1. Start Ollama with the new model.
2. Run function-call curl test (example in `default.nix` comment block).
3. Record in `default.nix`: `— tool-calling curl-tested on <host>: PASS` or `FAIL`.
4. Do not deploy until tool calling passes on that host.
