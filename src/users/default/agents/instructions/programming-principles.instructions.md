---
description: "Use when writing any code: general best-practice programming principles, patterns, and architectural standards organized by priority for AI agents."
name: "Programming Principles and Patterns"
applyTo: "**"
alwaysApply: true
---

Default coding policy for all code. Principles are tiered by priority: higher tiers address failure modes most specific to AI agents.

## Tier 1: Scope control, type safety, and safety guardrails

Highest priority. Directly counters over-engineering, prevents hallucinated scope, stops destructive edits to legacy logic, and forces compile-time correctness at boundaries.

- **Chesterton's Fence:** Never delete, bypass, or refactor legacy code, timing delays, or defensive checks until you have fully verified why they were introduced. Assume existing code has a reason to exist — find it before removing it.
- **KISS and YAGNI:** Implement the minimal correct solution that satisfies the current requirement. Reject premature abstractions, custom frameworks, and dynamic configuration systems unless explicitly requested. Prefer straight-line code and standard library calls over pattern-heavy architectures. Do not anticipate future requirements.
- **Make invalid states unrepresentable:** Use sum types (enums/tagged unions), constrained wrappers, and narrow domain types so illegal states cannot compile or exist at runtime. A type-level constraint is checked once by the compiler; runtime validation must be repeated at every boundary and is never fully provable.
- **Parse, don't validate:** Convert untrusted raw inputs (String, Int, JSON) into strongly-typed domain objects at system boundaries (API handlers, CLI entry points, file readers). After parsing, the typed value is trusted and needs no further validation. Internal domain functions receive pre-validated, strongly-typed inputs. The same principle applies to catch-all types from untyped boundaries — see `typing-conventions.instructions.md` for the untyped-value handling hierarchy, including when assertions at boundaries are acceptable.
- **Single Responsibility (SRP) and Separation of Concerns:** Every module, class, or function must have one clear reason to change. Separate business logic from I/O, database access, and UI formatting. Isolate side effects at the edges of the system.

## Tier 2: Error execution and resource lifecycle

Enforces clean error propagation, eliminates resource leaks, and keeps codebase edits self-correcting and incrementally clean.

- **Boy Scout Rule:** Leave code cleaner than you found it. When modifying a file, fix minor readability issues (cryptic variable names, missing types, dead comments) without exceeding the task scope.
- **Fail fast and defensive boundaries:** Detect invalid arguments, broken preconditions, or null states immediately at routine entry points. Abort execution or return an error — do not propagate garbage data hoping a downstream handler catches it. Never substitute a default value for a missing or failed result; surface the error instead.
- **RAII and explicit ownership:** Bind resource lifecycles (file handles, sockets, locks, allocated memory) strictly to object lifetimes with deterministic cleanup on scope exit. Prefer borrowing or references for read-only access over copying. Let the standard library manage low-level resource ownership.
- **Railway-oriented programming:** Model operations with sequential failable steps using monadic error pipelines (Result/Either) instead of scattered try/catch blocks or defensive if/else checks deep in business logic. This makes error paths explicit and composable.
- **Shotgun parsing avoidance:** Complete all validation and decoding at the entry point. Internal domain functions must accept pre-validated, strongly-typed inputs — no piecemeal parsing scattered across the call chain.

## Tier 3: Architecture and abstraction guidelines

Shapes class/module structures to be maintainable, avoiding deep inheritance trees and tight coupling across domain boundaries.

- **Command-Query Separation (CQS):** Functions must either execute a side effect (Command) or return data (Query) — never both.
- **Composition over inheritance:** Combine focused, single-purpose components rather than creating or extending deep inheritance hierarchies. Favor interfaces/protocols over abstract base classes for defining contracts.
- **DRY (Don't Repeat Yourself):** Extract duplicated logic into shared functions or modules. One fact, one representation, one source of truth. Do not repeat the same logic across multiple call sites.
- **Law of Demeter:** Do not navigate deep object chains (avoid `a.getB().getC().getD()`). Interact only with direct dependencies. If you need data from a transitive dependency, expose a method on the direct dependency.
- **Smart constructor pattern:** Expose private or restricted constructors paired with explicit validation factory methods (returning Result or Option) to enforce invariants upon object creation. This guarantees no invalid instance can exist without going through validation.
- **Tell, Don't Ask:** Instruct domain objects to execute operations rather than querying their internal state to make decisions externally. Encapsulate behavior with data.

## Tier 4: Domain and situational patterns

Crucial when writing network services, concurrent code, or running automated test loops, but lower priority for local logic edits.

- **AAA and FIRST testing:** Structure test suites using Arrange (set up state), Act (execute the behavior), Assert (verify the outcome). Ensure tests are Fast, Isolated, Repeatable, Self-validating, and Timely.
- **Circuit breaker and backoff with jitter:** For external network calls or distributed interfaces, employ resilience idioms to prevent cascading failures. Use exponential backoff with randomized jitter for retries.
- **Immutability by default:** Mark data structures immutable wherever possible to avoid race conditions and simplify state reasoning. See `typing-conventions.instructions.md` and `core-behavior.instructions.md` for language-specific immutable-by-default rules. This principle is already well-covered elsewhere — these instructions defer to those files.
- **SOLID principles (OCP, LSP, ISP, DIP):** Open for extension, closed for modification. Subtypes must satisfy base-type contracts (Liskov Substitution). Segregate interfaces so consumers depend only on methods they use. Depend on abstractions, not concretions.

## Related instruction files

- `authoring.instructions.md` — Markdown authoring conventions, document structure, and formatting rules.
- `core-behavior.instructions.md` — Agent operational model (communication, subagent delegation, terminal hygiene, git rules, premise integrity).
- `execution-details.instructions.md` — Tool recovery, multi-edit recovery, and investigation protocol.
- `maintain.instructions.md` — Codebase maintainability workflow (atomic commits, safety rules, broad cleanup patterns).
- `typing-conventions.instructions.md` — Language-specific type-level conventions (immutability per language, abstract over concrete, no catch-all types, structural typing).
