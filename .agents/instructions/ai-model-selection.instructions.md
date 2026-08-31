---
description: "Use when adding, updating, or reviewing AI model selections in src/modules/ai/models.json, VS Code chatLanguageModels host files, scripts/ai-sync.sh, src/platforms/Windows/modules/Invoke-AISync.ps1, or src/modules/ai/default.nix. Covers host-name key convention, hardware constraints per host, quantization guidance, required cross-file sync steps, and tool-calling verification requirements."
name: "AI Model Selection"
applyTo: "src/modules/ai/**, src/users/*/vscode/chatLanguageModels.*.json, src/hosts/*/ai.nix, scripts/ai-sync.sh, scripts/ai-sync.ps1, src/platforms/Windows/modules/system/Invoke-AISync.ps1, src/platforms/Windows/modules/system/Sync-LiteLLMService.ps1, src/modules/ai/litellm-config.yml"
---

# AI Model Selection

## Profile key convention

`src/modules/ai/models.json` groups model lists by **host name**, not by platform nickname. Use the exact OS hostname as keys (PascalCase, matching `networking.hostName` / `ComputerName` on each host):

| Key | Host | Resolved by |
| --------- | ------------- | -------------------------------------- |
| `MacBook` | macOS | `ai-sync.sh` Darwin branch |
| `NixOS` | NixOS (Linux) | `ai-sync.sh` wildcard branch |
| `Windows` | Windows | `Invoke-AISync.ps1` (always `Windows`) |

Do **not** use lowercase names like `"macbook"`, `"nixos"`, or `"windows"` — the keys must match the exact OS hostname (see `AGENTS.md` **Host name equals display name** policy). Do **not** use generic names like `"mac"` or `"pc"`. When adding a new host, add a new key matching its exact OS hostname and update the profile detection logic in both `ai-sync.sh` and `Invoke-AISync.ps1`.

## Hardware constraints per host

| Host | Memory budget | Notes |
| --------- | ------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------- |
| `MacBook` | ≤ 16 GB GPU (slight excess ~17–18 GB is OK) | 24 GB unified RAM; Apple Silicon Metal; flash attention + q4_0 KV cache enabled |
| `NixOS` | ≤ 6 GB discrete VRAM (model file ≤ ~5 GB target) | GPU acceleration enabled via `services.ollama.acceleration = "cuda"`; `MemoryMax = "16G"` systemd cap remains in effect |
| `Windows` | ≤ 6 GB discrete VRAM (same assumption as `NixOS`) | Same hardware class as NixOS PC; update if specs differ |

## Required cross-file sync

When changing model selections, update all of the following in the same change:

1. `src/modules/ai/models.json` host model lists.
2. `src/users/default/vscode/chatLanguageModels.MacBook.json`
3. `src/users/default/vscode/chatLanguageModels.NixOS.json`
4. `src/users/default/vscode/chatLanguageModels.Windows.json`
5. Manifest comment block in `src/modules/ai/default.nix`.

Each host's `chatLanguageModels.<host>.json` IDs must match (or be a subset of) that host key in `models.json`. Never leave stale editor entries for models absent from the host manifest.

## Quantization guidance

Ollama model tags follow `<base>-<quant>` naming. Key quantizations:

| Tag suffix | Typical size vs Q4_K_M | Quality vs Q4_K_M | When to use |
| --------------- | ---------------------------- | ----------------- | ------------------------------------------------------------------------------------ |
| `q4_K_M` | baseline (default) | baseline | Default; best quality/size tradeoff for most models |
| `q8_0` | ~1.7× larger | noticeably better | MacBook only when headroom allows; never for NixOS/Windows |
| `fp16` / `bf16` | ~2× larger | near-lossless | MacBook only for small models (e.g. e4b) where size allows |
| `it-qat` | same as Q4_K_M | approaches BF16 | Preferred over plain Q4_K_M for Gemma models that ship QAT variants (gemma3, gemma4) |
| `nvfp4` | slightly smaller than Q4_K_M | similar | NVIDIA GPU only (NixOS/Windows with NVIDIA); not for MacBook Metal |
| `mxfp8` | ~1.5× Q4_K_M | good | NVIDIA GPU or Apple MLX only |
| `mlx-bf16` | ~2× Q4_K_M | near-lossless | Apple MLX only; MacBook with sufficient headroom |

## Model selection preference

Prefer the larger parameter count over better quantization, per host:

- `qwen3.5:27b` (17 GB, 27B params, `q4_K_M`) over `qwen3:14b-q8_0` (16 GB, 14B params, `q8_0`) for the MacBook slot.
- 27B `q4_K_M` over 14B `q8_0` even at similar sizes — more parameters outweigh the quantization quality gap.

VRAM budget ceilings still apply: MacBook ≤ ~18 GB (slight excess OK); NixOS/Windows ≤ 6 GB (strict — no excess).

## Quantization rules

Available quantizations in the relevant size range: `q4_K_M` (default), `q8_0`, `fp16`/`bf16`, plus hardware-specific formats (`nvfp4`, `mxfp8`, `mlx-bf16`). No q3 or lower GGUF variants exist in Ollama for any model in this repository.

- **MacBook**: `q4_K_M` default; `it-qat` when the model family ships one (e.g. `gemma3:27b-it-qat`). `e4b-it-bf16` (16 GB) for `gemma4:e4b` when maximum quality is desired for a single small model.
- **NixOS / Windows**: `q4_K_M` only — VRAM is tight.

## Model size canonical source

Model tags, sizes, and capability metadata live in `src/modules/ai/models.json` and the manifest comment block in `src/modules/ai/default.nix`. Read those sources when evaluating fit — do not duplicate volatile size tables here.

## Tool-calling verification

Before committing a model change that relies on tool calling:

1. Start the Ollama server with the new model.
2. Run a function-call curl test (see `src/modules/ai/default.nix` comment block for an example invocation).
3. Record the result in `default.nix`: `— tool-calling curl-tested on <host>: PASS` or `FAIL`.
4. Do not deploy as the primary agent model until tool calling passes on that host.
