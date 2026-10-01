---
description: "Use when writing code: type-level conventions for interfaces, mutability, generics, and invariants. Covers abstract-over-concrete discipline, collection-precision, structural typing, catch-all prohibition, and type-system invariants."
name: "Typing Conventions"
applyTo: "**"
alwaysApply: true
---

Default typing policy for all code.

- **Immutable by default.** Reach for the read-only variant first, in every language. Use a mutable type only with a documented reason immutability cannot work. `const` over `let`/`var`; `readonly` properties; `readonly T[]`, `ReadonlyMap`, `ReadonlySet`; frozen dataclasses; read-only borrows over mutable references.
- **Abstract over concrete in public signatures.** Parameters, class attributes, and module-level declarations take the most general abstract type available (interface, protocol, abstract base class). Concrete types belong to construction and instantiation sites. Static dispatch: Rust `impl Trait`, TypeScript `<T extends Interface>`, Java bounded wildcards, Go `Interface` parameters, Swift `some Protocol`. Dynamic dispatch: Rust `dyn Trait` on returns and struct fields, TypeScript wide interface types, Java raw types, Swift `any Protocol`.
- **Narrowest type that supports the operations.** Ordered access needs an ordered type (`Sequence`, `Seq`), not a general collection. Set semantics or O(1) membership need a set. No general collection where a specific one fits.
- **Prefer abstract for returns.** A concrete return type is acceptable when it carries guarantees worth pinning down (construction results, serialization formats), not when it constrains future changes.
- **Structural typing over inheritance.** Define contracts by the operations an object supports (protocol, interface, type class). Reserve class inheritance for implementation sharing.
- **Fully parameterize generics.** A bare `list`, `dict`, `List`, `Map`, `array`, `Vec`, `ArrayList`, `NSArray`, or Kotlin `List<*>` discards the type information the signature exists to carry.
- **No catch-all types.** Never `any` (TypeScript), `Any` (Swift, Kotlin), `Object` (Java), `object` (Python, C#), `Box<dyn Any>` (Rust). TypeScript `unknown` is sound and forces narrowing.
- **No type-error suppression.** Not `# type: ignore`, `@ts-ignore`, `@ts-expect-error`, `@SuppressWarnings`, `// NOLINT`. When bypassing the type system on purpose (a test with deliberately wrong types), use an explicit checked cast that yields a correctly-typed value.
- **No silent defaulting of missing values.** No `or ""`, `?? ""`, `|| ""`, `dict.get(k, "")`, `unwrap_or("")`, swallowing `except`, or `-ErrorAction SilentlyContinue` without a stated reason. Surface the failure so the caller decides. This is a value-masking fallback, banned by `core-behavior.instructions.md`.
- **No non-null assertions.** TypeScript and Dart postfix `!`, Kotlin `!!`, Swift force unwrap, C# null-forgiving `!`, Rust `.unwrap()`/`.expect()`. Use narrowing, early return, optional chaining, or `?`.
- **`assert` is test-only.** In production code use real error handling. The exception is a runtime invariant whose violation must halt execution.

Language defaults:

| Language | Immutable first |
| --- | --- |
| TypeScript | `readonly` properties, `readonly T[]`, `ReadonlyMap`/`ReadonlySet`, `Readonly<T>`, `as const` |
| Rust | `let`, `&T`, immutable fields, no `&mut self` |
| Python | `Sequence[T]`, `Mapping[K,V]`, `frozenset`, `@dataclass(frozen=True)`, return copies |
| Java | `List.of()`, `Set.of()`, `Map.of()`, `Collections.unmodifiable*`, `final` fields, records |
| C# | records with init-only properties, `readonly` structs, `IReadOnlyList<T>`, `IReadOnlyDictionary<K,V>` |
| Swift | `let`, structs over classes, value types for data models |
| Kotlin | `val`, `listOf()` over `mutableListOf()`, read-only interfaces |
| PowerShell | `[Array]` (already fixed), `ReadOnlyCollection[T]` over `[List[T]]`, no `[ref]` params |
| Shell | `local` and `readonly`, subshells for scoped state |
| Nix | pure `let ... in`, no `let inherit;`, `builtins.map`/`filter`/`foldl'` over mutation |

## Untyped boundaries

A catch-all type arriving from an untyped source gets handled in this order. Levels 1 and 2 need no justification; levels 3 and 4 do.

1. Narrow to the known type when context gives the shape (documented contract, validated schema, typed matcher).
2. Widen to an opaque or unknown type when no compile-time information exists, then narrow at runtime.
3. Assert the type when runtime narrowing is infeasible but the type is verified elsewhere. Needs an inline comment on why narrowing is insufficient and why the assertion is sound.
4. Assert through an opaque intermediate when the types are structurally incompatible. Needs a comment on why the intermediate is needed.

`as any` is never acceptable. In TypeScript: `: T` when the expected type is known, `: unknown` when it is not, `as T` with a comment, `as unknown as T` with a comment. `satisfies T as U` only when `T` and `U` are the same type; with different types the `as` alone decides the result.

| Pattern | Approach |
| --- | --- |
| Matcher in typed context | `expect.any(Number) satisfies number as number` |
| Matcher, unknown inline | `expect.anything() satisfies unknown as unknown` |
| Unparameterized `vi.fn()` | `vi.fn<() => string>(() => "test")` |
| Unparameterized matcher | `expect.objectContaining<Record<string, unknown>>({...})` |
| Callback param inference | `vi.fn((cb: (v: string) => unknown) => {...})` |
| `Object.create(null)` | `... satisfies Record<string, unknown> as Record<string, unknown>` |
| Discriminated union | Check `.type` first, then access `.value` |
| Structurally incompatible | `{} as unknown as WorkspaceLeaf` |
| Stdlib `any` | `as T` plus a comment on why narrowing fails |
| Raw pointer cast (Rust) | `*const T as *const U` with reason |
| `Any` from an untyped boundary (Python) | `isinstance(x, T)`, or `cast(T, x)` with reason |
| `object`/`dynamic` (C#) | `is` pattern match |
| Test idiom suppression | `// eslint-disable-next-line -- <why intentional>` |
