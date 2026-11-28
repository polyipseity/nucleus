---
description: "Use when choosing tools on a nucleus-provisioned machine. Lists installed nucleus commands, provisioned tools, and ecosystem conventions for any repository."
name: "Nucleus Provisioned Tools"
applyTo: "**"
alwaysApply: true
---

# Nucleus provisioned tools

This host is provisioned by nucleus. The tools below are installed and managed; prefer them over ad-hoc installs. For boundary and behavior precedence, follow `standing-orders.instructions.md`.

## Nucleus commands

Inside a nucleus repository, prefer the `nucleus-*` wrapper over `./scripts/*.sh` or `./scripts/*.ps1`. Repository-internal code must not shell out to a PATH `nucleus-*` command; call the script entry, flake attr, or store path instead.

| Command | Purpose |
| --- | --- |
| `nucleus-ai` | Manage AI models and endpoints. |
| `nucleus-apply` | Apply the nucleus configuration to this host. |
| `nucleus-bootstrap` | Install Nix and base dependencies on a bare machine. |
| `nucleus-camilladsp-heartbeat` | Run or probe the CamillaDSP heartbeat daemon. |
| `nucleus-check` | Run repository validation checks. |
| `nucleus-cloud` | Manage cloud mounts and replica sync. |
| `nucleus-config` | Read and write nucleus runtime configuration. |
| `nucleus-gc` | Clean caches, generations, logs, and stale artifacts. |
| `nucleus-logs` | Append, rotate, query, and label nucleus logs. |
| `nucleus-svc` | List and control nucleus services. |
| `nucleus-test` | Run the repository test suite. |
| `nucleus-update` | Update flake inputs and managed lock state. |
| `nucleus-utils` | Run nucleus utility subcommands. |
| `nucleus-vm` | Provision and manage virtual machines. |

`codex` is registry-managed with installs disabled. Only its `~/.codex/config.toml` LiteLLM slot is provisioned.

## Provisioned tools

Each tool below is installed on this machine. Links go to official documentation; this file does not teach usage.

### Media and OCR

- [`ffmpeg`](https://ffmpeg.org/documentation.html): media processing.
- [`yt-dlp`](https://github.com/yt-dlp/yt-dlp#readme): media download; use `deno` when a tool requires it.
- [`whisper-cli`](https://github.com/ggml-org/whisper.cpp) ([`whisper-cpp`](https://github.com/ggml-org/whisper.cpp)): local speech to text with managed models under nucleus roots.
- [`paddleocr`](https://github.com/PaddlePaddle/PaddleOCR): OCR.

### Search and data

- [`rg` / `ripgrep`](https://github.com/BurntSushi/ripgrep/blob/master/GUIDE.md): text search.
- [`fd`](https://github.com/sharkdp/fd#how-to-use): file search.
- [`jq`](https://jqlang.org/manual/): JSON processing.
- [`yq-go`](https://mikefarah.gitbook.io/yq) (`yq`): YAML, JSON, and XML processing.

### Runtimes and package tools

- [`bun`](https://bun.sh/docs): default JavaScript runtime and package manager.
- [`deno`](https://docs.deno.com/): JavaScript and TypeScript runtime for tools that require it.
- [`uv`](https://docs.astral.sh/uv/): Python package and tool runner.
- [`cargo-binstall`](https://github.com/cargo-bins/cargo-binstall#readme): install prebuilt Rust binaries.
- [`rustup`](https://rust-lang.github.io/rustup/): Rust toolchain manager.
- [`python`](https://docs.python.org/3/): Python runtime.
- [`dotnet-runtime-6`](https://learn.microsoft.com/dotnet/core/whats-new/dotnet-6): .NET 6 runtime.
- [`jdk`](https://adoptium.net/docs/): Java development kit.

### Deletion and recovery

- [`rip2`](https://github.com/nivekuil/rip#readme) (`rip`): recoverable deletion to a graveyard.
- [`safe-rm`](https://www.npmjs.com/package/safe-rm): recoverable `rm` wrapper. Follow `file-deletion-safety.instructions.md` and never invoke raw deletion commands directly.

### Shell, files, and archives

- [`7zip`](https://www.7-zip.org/): archive utility.
- [`bat`](https://github.com/sharkdp/bat#how-to-use): file viewer.
- [`bottom`](https://clementtsang.github.io/bottom/stable/): system monitor.
- [`direnv`](https://direnv.net/): directory environment loader.
- [`dos2unix`](https://waterlan.home.xs4all.nl/dos2unix.html): line ending conversion.
- [`duti`](https://github.com/moretension/duti): default application handler on macOS.
- [`eza`](https://eza.rocks/): directory listing.
- [`fzf`](https://junegunn.github.io/fzf/): fuzzy finder.
- [`ncdu`](https://dev.yorhel.nl/ncdu/man): disk usage browser.
- [`rclone`](https://rclone.org/docs/): cloud and remote file sync.
- [`sqlite`](https://www.sqlite.org/docs.html): SQLite database engine.
- [`starship`](https://starship.rs/config/): shell prompt.
- [`zoxide`](https://github.com/ajeetdsouza/zoxide#readme): directory jumper.

### Development and source control

- [`actionlint`](https://github.com/rhysd/actionlint/blob/main/docs/usage.md): GitHub Actions linting.
- [`android-tools`](https://developer.android.com/tools/releases/platform-tools): Android platform tools.
- [`asciinema`](https://docs.asciinema.org/): terminal recording.
- [`cargo-cache`](https://github.com/matthiaskrgr/cargo-cache#readme): Cargo cache management.
- [`cargo-nextest`](https://nexte.st/): Rust test runner.
- [`check-jsonschema`](https://check-jsonschema.readthedocs.io/): JSON Schema validation.
- [`claude-code`](https://docs.anthropic.com/en/docs/claude-code/overview): Anthropic Claude Code CLI.
- [`clink`](https://chrisant996.github.io/clink/): Windows command line editing.
- [`deadnix`](https://github.com/astro/deadnix#readme): Nix dead code detection.
- [`gh`](https://cli.github.com/manual/): GitHub CLI.
- [`git`](https://git-scm.com/docs): version control.
- [`git-filter-repo`](https://github.com/newren/git-filter-repo#readme): repository history rewriting.
- [`git-lfs`](https://git-lfs.com/): Git large file storage.
- [`mold`](https://github.com/rui314/mold#readme): linker.
- [`nix-index`](https://github.com/nix-community/nix-index#readme): Nix file index.
- [`nixd`](https://github.com/nix-community/nixd/blob/main/nixd/docs/editor-setup.md): Nix language server.
- [`nixf`](https://github.com/nix-community/nixd/tree/main/nixf): Nix formatter and linter tooling.
- [`nixfmt`](https://github.com/NixOS/nixfmt#readme): Nix formatter.
- [`opencode`](https://opencode.ai/docs): coding agent CLI.
- [`packer`](https://developer.hashicorp.com/packer/docs): image builder.
- [`pay-respects`](https://github.com/iffse/pay-respects#readme): command-line typo correction.
- [`pinact`](https://github.com/suzuki-shunsuke/pinact#readme): GitHub Actions pinning.
- [`prek`](https://github.com/j178/prek#readme): pre-commit hook runner.
- [`ruff`](https://docs.astral.sh/ruff/): Python linting and formatting.
- [`sccache`](https://github.com/mozilla/sccache#readme): compiler cache.
- [`shellcheck`](https://www.shellcheck.net/): shell script linting.
- [`shfmt`](https://github.com/mvdan/sh#shfmt): shell formatting.
- [`taplo`](https://taplo.tamasfe.dev/): TOML tooling.
- [`ty`](https://docs.astral.sh/ty/): Python type checking.
- [`typst`](https://typst.app/docs/): document typesetting.
- [`yamllint`](https://yamllint.readthedocs.io/): YAML linting.
- [`zizmor`](https://docs.zizmor.sh/): GitHub Actions security analysis.

### Nix, Nickel, and build tooling

- [`nickel`](https://nickel-lang.org/user-manual/): Nickel language.
- [`nickel-lang-lsp`](https://github.com/tweag/nickel/tree/master/lsp): Nickel language server (`nls`).
- [`nls`](https://github.com/tweag/nickel/tree/master/lsp): Nickel language server binary.
- [`llvm`](https://llvm.org/docs/): LLVM toolchain.
- [`llvm-clang`](https://clang.llvm.org/docs/): C and C++ compiler.
- [`llvm-lld`](https://lld.llvm.org/): LLVM linker.
- [`llvm-lldb`](https://lldb.llvm.org/): LLVM debugger.
- [`scoop`](https://scoop.sh/): Windows package manager used in provisioning.
- [`steamcmd`](https://developer.valvesoftware.com/wiki/SteamCMD): Steam command line tool.

### Security, secrets, and credentials

- [`gnupg`](https://gnupg.org/documentation/): OpenPGP and cryptography.
- [`gopass`](https://www.gopass.pw/docs/): password manager.
- [`pass`](https://www.passwordstore.org/): password store.
- [`pinentry_mac`](https://github.com/GPGTools/pinentry): GnuPG pinentry for macOS.
- [`sops`](https://github.com/getsops/sops#readme): secret encryption and decryption.
- [`ssh-to-age`](https://github.com/Mic92/ssh-to-age#readme): SSH to age key conversion.

### Networking, services, and virtualization

- [`alsa-utils`](https://www.alsa-project.org/wiki/Main_Page): ALSA utilities.
- [`caddy`](https://caddyserver.com/docs/): web server and reverse proxy.
- [`camilladsp`](https://henquist.github.io/): audio DSP engine.
- [`docker`](https://docs.docker.com/reference/cli/): container CLI.
- [`jellyfin`](https://jellyfin.org/docs/): media server.
- [`litellm`](https://docs.litellm.ai/): LLM proxy and gateway.
- [`ollama`](https://github.com/ollama/ollama/tree/main/docs): local model runtime.
- [`qemu`](https://www.qemu.org/documentation/): machine emulator and virtualizer.
- [`redis`](https://redis.io/docs/latest/): in-memory data store.
- [`sandbox-runtime`](https://github.com/anthropic-experimental/sandbox-runtime): process sandbox runtime.
- [`vagrant`](https://developer.hashicorp.com/vagrant/docs): development environment manager.
- [`winfsp`](https://winfsp.dev/doc/): Windows file system proxy support.

### Media, document, and analysis utilities

- [`deep-filter`](https://github.com/Rikorose/DeepFilterNet): speech enhancement.
- [`desktoppr`](https://github.com/scriptingosx/desktoppr#readme): macOS desktop picture control.
- [`equaliser`](https://github.com/eqMac/eqMac): audio equalizer tooling.
- [`exiftool`](https://exiftool.org/): metadata inspection and editing.
- [`ghostscript`](https://ghostscript.readthedocs.io/): PostScript and PDF processing.
- [`glaxnimate`](https://glaxnimate.mattbas.org/manual/): vector animation editor assets and tooling.
- [`imagemagick`](https://imagemagick.org/script/command-line-processing.php): image processing.
- [`mas`](https://github.com/mas-cli/mas#readme): Mac App Store CLI.
- [`mat2`](https://0xacab.org/jvoisin/mat2#readme): metadata removal.
- [`neovim`](https://neovim.io/doc/): text editor.
- [`powersession`](https://github.com/Watfaq/PowerSession#readme): PowerShell session recording.
- [`powershell`](https://learn.microsoft.com/powershell/): PowerShell shell and runtime.
- [`sigrok-cli`](https://sigrok.org/wiki/Sigrok-cli): signal analysis CLI.

### Managed package, agent, and extension tools

These names come from the managed package manifests and may be libraries, plugins, or package identities installed by their manager.

- Bun globals: [`@anthropic-ai/sandbox-runtime`](https://github.com/anthropic-experimental/sandbox-runtime), [`@earendil-works/pi-coding-agent`](https://github.com/badlogic/pi-mono), [`@tobilu/qmd`](https://github.com/tobilu/qmd), [`clawhub`](https://clawhub.ai/).
- uv tools: [`discord-music-rpc`](https://github.com/patryk-ku/discord-music-rpc), [`hermes-agent`](https://github.com/NousResearch/hermes-agent).
- pi extensions and packages: [`@getpipher/vision`](https://www.npmjs.com/package/@getpipher/vision), [`@juicesharp/rpiv-ask-user-question`](https://www.npmjs.com/package/@juicesharp/rpiv-ask-user-question), [`@narumitw/pi-plan-mode`](https://www.npmjs.com/package/@narumitw/pi-plan-mode), [`@narumitw/pi-usage`](https://www.npmjs.com/package/@narumitw/pi-usage), [`better-custom`](https://www.npmjs.com/package/better-custom), [`pi-background-tasks`](https://www.npmjs.com/package/pi-background-tasks), [`pi-extmgr`](https://www.npmjs.com/package/pi-extmgr), [`pi-goal-x`](https://www.npmjs.com/package/pi-goal-x), [`pi-memory`](https://www.npmjs.com/package/pi-memory), [`pi-powerline-footer`](https://www.npmjs.com/package/pi-powerline-footer), [`pi-provider-litellm`](https://www.npmjs.com/package/pi-provider-litellm), [`pi-simplify`](https://www.npmjs.com/package/pi-simplify), [`pi-subagents`](https://www.npmjs.com/package/pi-subagents), [`pi-web-access`](https://www.npmjs.com/package/pi-web-access), [`pi-coding-agent`](https://github.com/badlogic/pi-mono).
- Scoop and manifest package names: [`inter`](https://rsms.me/inter/), [`iwck`](https://github.com/Nigh/I-wanna-clean-keyboard), [`notosanscjk`](https://github.com/notofonts/noto-cjk), [`notoserifcjk`](https://github.com/notofonts/noto-cjk), [`source-serif`](https://github.com/adobe-fonts/source-serif), [`zig`](https://ziglang.org/documentation/master/).

## Ecosystem conventions

- Python: prefer `uv tool install`, `uvx`, and `uv run` over ad-hoc system installs.
- JavaScript: use `bun` as the default runtime. Use `deno` for tools that require it, such as `yt-dlp`.
- Rust: prefer `cargo-binstall`, then `cargo install`. Keep `rustup` default at `none`.

## Safety and environment

- Safe deletion: follow `file-deletion-safety.instructions.md`. `rip2` and `safe-rm` wrappers are the recoverable paths; do not invoke raw deletion commands directly.
- Sandbox: detect with `SANDBOX_RUNTIME`. When it is set, the process runs inside the managed sandbox, so writes, network access, and deletion behavior follow sandbox policy. When it is unset, the process runs outside that sandbox and must still follow repository and host safety rules.
- Nucleus roots and secrets: nucleus state lives under the managed nucleus roots, and secrets are provisioned material; do not copy secrets into ad-hoc locations or invent replacement stores.
- Provisioning: if a needed tool is missing or broken, fix provisioning instead of improvising a system-wide install.
