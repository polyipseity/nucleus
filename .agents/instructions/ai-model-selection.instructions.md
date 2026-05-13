---
description: "Use when adding, updating, or reviewing AI model selections in src/modules/ai/models.json, scripts/ai-sync.sh, src/hosts/windows/modules/Invoke-AiSync.ps1, or src/modules/ai/default.nix. Covers host-name key convention, hardware constraints per host, quantization guidance, and tool-calling verification requirements."
name: "AI Model Selection"
applyTo: "src/modules/ai/**, scripts/ai-sync.sh, scripts/ai-sync.ps1, src/hosts/windows/modules/Invoke-AiSync.ps1"
---

# AI Model Selection

## Profile key convention

`src/modules/ai/models.json` groups model lists by **host name**, not by
platform nickname.  Use the exact host names as keys:

| Key        | Host           | Resolved by                             |
| ---------- | -------------- | --------------------------------------- |
| `macbook`  | macOS          | `ai-sync.sh` Darwin branch              |
| `nixos`    | NixOS (Linux)  | `ai-sync.sh` wildcard branch            |
| `windows`  | Windows        | `Invoke-AiSync.ps1` (always `windows`)  |

Do **not** use generic names like `"mac"` or `"pc"` — they break when a
second host of the same OS type is added and make the manifest ambiguous.
When adding a new host, add a new key matching its host name and update the
profile detection logic in both `ai-sync.sh` and `Invoke-AiSync.ps1`.

## Hardware constraints per host

These are the authoritative assumptions for model size budgeting.  Update
this table whenever hardware changes.

| Host      | Memory budget                                      | Notes                                                                               |
| --------- | -------------------------------------------------- | ----------------------------------------------------------------------------------- |
| `macbook` | ≤ 16 GB GPU (slight excess ~17–18 GB is OK)        | 24 GB unified RAM; Apple Silicon Metal; flash attention + q4_0 KV cache enabled     |
| `nixos`   | ≤ 6 GB discrete VRAM (model file ≤ ~5 GB target)  | GPU acceleration currently disabled (CPU-only); budget applies if GPU is ever enabled; `MemoryMax = "16G"` systemd cap regardless |
| `windows` | ≤ 6 GB discrete VRAM (same assumption as `nixos`)  | Same hardware class as nixos PC; update if specs differ                             |

## Quantization guidance

Ollama model tags follow `<base>-<quant>` naming.  Key quantizations:

| Tag suffix    | Typical size vs Q4_K_M | Quality vs Q4_K_M | When to use                                             |
| ------------- | ---------------------- | ----------------- | ------------------------------------------------------- |
| `q4_K_M`      | baseline (default)     | baseline          | Default; best quality/size tradeoff for most models     |
| `q8_0`        | ~1.7× larger           | noticeably better | macbook only when headroom allows; never for nixos/windows |
| `fp16` / `bf16` | ~2× larger           | near-lossless     | macbook only for small models (e.g. e4b) where size allows |
| `it-qat`      | same as Q4_K_M         | approaches BF16   | Preferred over plain Q4_K_M for Gemma models that ship QAT variants (gemma3, gemma4) |
| `nvfp4`       | slightly smaller than Q4_K_M | similar    | NVIDIA GPU only (nixos/windows with NVIDIA); not for macbook Metal |
| `mxfp8`       | ~1.5× Q4_K_M           | good              | NVIDIA GPU or Apple MLX only                            |
| `mlx-bf16`    | ~2× Q4_K_M             | near-lossless     | Apple MLX only; macbook with sufficient headroom        |

## Model selection preference

When choosing between a larger model at a lower quantization vs a smaller
model at a higher quantization, **prefer the larger parameter count** even at
the cost of running the lower quantization.  Examples:

- Prefer `qwen3.5:27b` (17 GB, 27B params, `q4_K_M`) over `qwen3:14b-q8_0`
  (16 GB, 14B params, `q8_0`) for the macbook slot.
- Prefer a 27B `q4_K_M` model over a 14B `q8_0` model even if their sizes
  are similar, because more parameters usually outweigh the quantization
  quality gap at the same budget.
- Only choose a smaller model when the larger one genuinely cannot fit in the
  budget (including the ~17–18 GB slight-excess window for macbook).

This preference applies per-host and does **not** override the VRAM budget
ceilings: macbook ≤ ~18 GB (slight excess OK); nixos/windows ≤ 6 GB
(strict — the slight-excess allowance applies only to macbook).

## Quantization rules

Ollama's available quantizations for models in the relevant size range are
limited to `q4_K_M` (or equivalent), `q8_0`, `fp16`/`bf16`, and selected
hardware-specific formats (`nvfp4`, `mxfp8`, `mlx-bf16`).  There are **no
q3 or lower GGUF variants** available in Ollama for any model in this
repository's selection; do not expect or look for them.

- **macbook default**: `q4_K_M` (default tag); use `it-qat` when the model
  family ships one (e.g. `gemma3:27b-it-qat`).  Use `e4b-it-bf16` (16 GB)
  for `gemma4:e4b` when maximum quality at a single small model is desired.
- **nixos / windows default**: always `q4_K_M` (default tag) — VRAM is
  tight; do not use q8_0 or fp16 variants.
- Avoid lower-than-Q4 quantizations (Q3, Q2) — they do not exist on Ollama
  for the models tracked here and offer significant quality degradation.

## Model size reference (verified from Ollama library)

Sizes are download/VRAM footprint at default `q4_K_M` quantization unless noted.
All tags below confirmed to exist on Ollama as of 2026-05.

### macbook candidates (≤ 16 GB target; ≤ ~18 GB acceptable — high-param preferred)

Ordered by preference under the high-param-count policy.

| Model tag              | Size   | Capabilities                | Notes                                                        |
| ---------------------- | ------ | --------------------------- | ------------------------------------------------------------ |
| `qwen3.5:27b`          | 17 GB  | vision tools thinking       | **High-param pick**; 27B dense; 256K ctx; slight excess OK   |
| `qwen3.6:27b`          | 17 GB  | vision tools thinking       | 27B; 256K ctx; agentic coding focus; slight excess OK        |
| `gemma4:26b`           | 18 GB  | vision tools thinking       | MoE 26B/4B active; frontier benchmarks; slight excess OK     |
| `devstral:24b`         | 14 GB  | tools                       | 24B; 128K ctx; coding agent SWE-bench #1 open-source (46.8%) |
| `magistral:24b`        | 14 GB  | tools thinking              | 24B; 40K effective ctx (128K window); reasoning specialist   |
| `gemma4:e4b`           | 9.6 GB | vision tools thinking audio | Current; MoE 4B active; QAT; Apple Silicon Metal             |
| `qwen3:14b`            | 9.3 GB | tools thinking              | Current; 14B dense; 40K ctx                                  |
| `qwen3.5:27b-int4`     | 16 GB  | tools thinking              | 27B int4 text-only; just fits budget; no vision              |
| `qwen3:30b`            | 19 GB  | tools thinking              | MoE 30B/3B active; 256K ctx; ~3 GB over target — use cautiously |

### nixos / windows candidates (≤ 6 GB VRAM — strict; high-param preferred)

`qwen3:8b` (5.2 GB, `q4_K_M`) is the maximum-parameter model that fits within
6 GB VRAM at any Ollama-available quantization.  Ollama offers no sub-`q4_K_M`
variants for models in this size range.  The next size up (`qwen3.5:9b-q4_K_M`
= 6.6 GB, `qwen3:14b-q4_K_M` = 9.3 GB) all exceed the strict 6 GB budget.
The high-param preference does not change the selection here — `qwen3:8b` is
already the optimum.

| Model tag        | Size   | Fits 6 GB? | Capabilities          | Notes                                                       |
| ---------------- | ------ | ---------- | --------------------- | ----------------------------------------------------------- |
| `qwen3:8b`       | 5.2 GB | Yes        | tools thinking        | Current; maximum params within budget; 40K ctx              |
| `qwen3.5:9b`     | 6.6 GB | No         | vision tools thinking | 0.6 GB over — viable CPU-only on nixos (MemoryMax=16G); not for GPU slot |

## Tool-calling verification

Before committing a model change that relies on tool calling:

1. Start the Ollama server with the new model.
2. Run a basic function-call curl test (see `src/modules/ai/default.nix`
   comment block for an example invocation).
3. Record the result in the comment block in `default.nix`:
   `— tool-calling curl-tested on <host>: PASS` or `FAIL`.
4. Do not deploy a model as the primary agent model on a host until tool
   calling is verified on that host.

## Sorting

Keep model lists in `models.json` in alphabetical order within each host key.
