---
description: "Use when writing any code: general best-practice programming principles, patterns, and architectural standards organized by priority for AI agents."
name: "Programming Principles and Patterns"
applyTo: "**"
alwaysApply: true
---

Default coding policy for all code. Principles are tiered by priority: higher tiers address failure modes most specific to AI agents.

## Tier 1: scope control, type safety, safety guardrails

- **Chesterton's Fence:** Never delete, bypass, or refactor legacy code, timing delays, or defensive checks until you have verified why they exist. Find the reason before removing it.
- **KISS and YAGNI:** Implement the minimal correct solution for the current requirement. Reject premature abstractions, custom frameworks, and dynamic configuration systems unless asked. Prefer straight-line code and standard library calls over pattern-heavy architectures. Do not anticipate future requirements.
- **Make invalid states unrepresentable:** Use sum types (enums, tagged unions), constrained wrappers, and narrow domain types so illegal states cannot compile. Runtime validation still repeats at every boundary.
- **Parse, don't validate:** Convert untrusted input (String, Int, JSON) into typed domain objects at system boundaries (API handlers, CLI entry points, file readers). Internal functions then take typed input. `typing-conventions.instructions.md` covers the untyped-boundary hierarchy.
- **SRP and separation of concerns:** One clear reason to change per module, class, or function. Keep business logic apart from I/O, database access, and UI formatting. Isolate side effects at the edges.

## Tier 2: error execution and resource lifecycle

- **Boy Scout Rule:** While in a file, fix minor readability issues (cryptic names, missing types, dead comments) without exceeding the task scope.
- **Fail fast at defensive boundaries:** Detect invalid arguments, broken preconditions, and null states at routine entry points. Abort or return an error; never propagate garbage data downstream, and never substitute a default for a missing or failed result.
- **RAII and explicit ownership:** Bind resource lifetimes (file handles, sockets, locks, memory) to object lifetimes with deterministic cleanup. Prefer borrowing or references for read-only access over copying. Let the standard library own low-level resources.
- **Railway-oriented programming:** Model sequential failable steps as Result/Either pipelines instead of scattered try/catch blocks.
- **Shotgun parsing avoidance:** Complete all validation and decoding at the entry point; internal domain functions accept pre-validated input.

## Tier 3: architecture and abstraction

- **Command-query separation:** A function either executes a side effect or returns data, never both.
- **Composition over inheritance:** Combine focused, single-purpose components; favor interfaces and protocols over deep hierarchies.
- **DRY:** One fact, one representation, one source of truth. Extract logic repeated across call sites.
- **Law of Demeter:** Interact with direct dependencies only. Expose a method on the direct dependency rather than walking a deep object chain.
- **Smart constructors:** Pair restricted constructors with validation factories so no invalid instance can exist.
- **Tell, don't ask:** Domain objects execute operations rather than exposing state for external decisions.

## Tier 4: domain and situational patterns

- **AAA and FIRST testing:** Arrange, Act, Assert. Tests are Fast, Isolated, Repeatable, Self-validating, Timely.
- **Circuit breaker and backoff with jitter:** For external network calls and distributed interfaces, exponential backoff with randomized jitter.
- **SOLID:** Open for extension, closed for modification; subtypes honor base-type contracts; consumers depend only on methods they use; depend on abstractions, not concretions.
- **Immutability by default:** See `typing-conventions.instructions.md` and `core-behavior.instructions.md`.
