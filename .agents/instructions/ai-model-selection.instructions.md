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

Rules:
- **macbook default**: `q4_K_M` (default tag); use `it-qat` when the model
  family ships one (e.g. `gemma3:27b-it-qat`).  Use `e4b-it-bf16` (16 GB)
  for `gemma4:e4b` when maximum quality at a single small model is desired.
- **nixos / windows default**: always `q4_K_M` (default tag) — VRAM is
  tight; do not use q8_0 or fp16 variants.
- Avoid lower-than-Q4 quantizations (Q3, Q2) except for emergency RAM
  reduction; quality degradation at those levels is significant.

## Model size reference (verified from Ollama library)

Sizes are download/VRAM footprint at default `q4_K_M` quantization unless noted.

### macbook candidates (≤ 16 GB; ~17–18 GB acceptable)

| Model tag                  | Size   | Capabilities                | Notes                                          |
| -------------------------- | ------ | --------------------------- | ---------------------------------------------- |
| `gemma4:e4b`               | 9.6 GB | vision tools thinking audio | Current; QAT-optimized for Apple Silicon Metal |
| `gemma4:e4b-it-bf16`       | 16 GB  | vision tools thinking audio | Max quality for e4b; fills the 16 GB budget    |
| `gemma4:26b`               | 18 GB  | vision tools thinking       | MoE, 4B active; top benchmark scores; slight excess |
| `gemma4:e2b`               | 7.2 GB | vision tools thinking audio | Smaller sibling; faster inference              |
| `qwen3:14b`                | 9.3 GB | tools thinking              | Current; 40K ctx                               |
| `qwen3:14b-q8_0`           | 16 GB  | tools thinking              | Higher quality qwen3:14b; fills budget         |
| `qwen3.5:27b`              | 17 GB  | vision tools thinking       | 256K ctx; multimodal upgrade over qwen3        |
| `qwen3.5:27b-int4`         | 16 GB  | tools thinking              | Text-only int4 variant; just fits budget       |
| `qwen3.6:27b`              | 17 GB  | vision tools thinking       | 256K ctx; agentic coding focus                 |
| `devstral:24b`             | 14 GB  | tools                       | Coding agent #1 open-source (SWE-bench 46.8%)  |
| `devstral-small-2:24b`     | 14 GB  | vision tools                | Newer devstral; adds vision                    |
| `mistral-small3.2:24b`     | 15 GB  | vision tools                | Robust function calling; 128K ctx              |
| `magistral:24b`            | 14 GB  | tools thinking              | Reasoning specialist; 128K ctx                 |
| `gemma3:27b-it-qat`        | 17 GB  | vision                      | QAT variant; quality ≈ BF16 at Q4 size; 128K ctx |

### nixos / windows candidates (≤ 6 GB VRAM; target model file ≤ 5 GB)

| Model tag          | Size   | Capabilities          | Notes                                                          |
| ------------------ | ------ | --------------------- | -------------------------------------------------------------- |
| `qwen3:8b`         | 5.2 GB | tools thinking        | Current; borderline — with q4_0 KV cache ~5.7 GB total        |
| `qwen3:4b`         | 2.5 GB | tools thinking        | Comfortable headroom; 256K ctx (instruct variant)              |
| `qwen3.5:4b`       | 3.4 GB | vision tools thinking | Adds vision; 256K ctx; clear headroom                         |
| `qwen3.5:9b`       | 6.6 GB | vision tools thinking | Exceeds 6 GB VRAM — only viable on CPU or with 8 GB VRAM      |
| `gemma3:4b`        | 3.3 GB | vision                | No tool calling; vision + 128K ctx; quality certified         |
| `gemma4:e2b`       | 7.2 GB | vision tools thinking | Exceeds 6 GB VRAM — only viable on CPU or with 8 GB VRAM      |

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
