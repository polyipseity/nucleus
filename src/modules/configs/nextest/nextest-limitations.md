# cargo-nextest limitations

cargo-nextest is the default managed Rust test runner on all nucleus hosts.
The following intentional limitations apply.  See the [nextest docs][nextest-docs] for details.

## 1. Doctests (`///` examples) — not executed

nextest deliberately skips documentation tests embedded in `///` comments.
These are compiled into separate binaries and nextest does not support
discovering or running them.

**Fix:** Run `cargo test --doc` alongside `cargo nextest run` in your CI
pipeline or commit hook.

## 2. Custom test harnesses (`harness = false`) — incompatible

When a Cargo.toml crate sets `harness = false`, standard `cargo test` delegates
control to a custom executable.  nextest requires `--list`/`--exact` CLI flags
that custom harnesses do not implement unless they use a compat library such as
`libtest-mimic`.

**Fix:** Run `cargo test` for crates that use `harness = false`, or migrate the
custom harness to use `libtest-mimic`.

## 3. Code coverage

To run coverage with nextest, install `cargo-llvm-cov` and run:

```
cargo install cargo-llvm-cov
cargo llvm-cov nextest
```

See the [nextest test-coverage docs][nextest-coverage] for CI integration and
doctest coverage merging.

## 4. IDE test runner — defaults to `cargo test`

Editors (VS Code, RustRover, Zed) use `cargo test` for inline "run test"
buttons.  To use nextest:

- **VS Code:** See the managed `rust-analyzer.runnables.test.overrideCommand`
  setting in `src/modules/configs/vscode/settings.json`.
- **RustRover:** *Settings → Build Tools → Cargo → Test Runner* → select
  "cargo-nextest".
- **Zed:** Add `"nextest": true` to your project's `.zed/settings.json`.

[nextest-docs]: https://nexte.st/
[nextest-coverage]: https://nexte.st/docs/integrations/test-coverage/
