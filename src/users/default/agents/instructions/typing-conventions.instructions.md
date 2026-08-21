---
description: "Use when writing code: type-level conventions for interfaces, mutability, generics, and invariants. Covers abstract-over-concrete discipline, collection-precision, structural typing, catch-all prohibition, and type-system invariants."
name: "Typing Conventions"
applyTo: "**"
alwaysApply: true
---

Default typing policy for all code.

- **Abstract over concrete in public interfaces.** In function signatures, class attributes, and module-level declarations, use the most general abstract type available (interfaces, protocols, abstract base classes). Use concrete types only for construction and instantiation; annotate variables with abstract types. Local variables may use narrower types.
- **Language equivalents:**
  - **Rust**: `impl Trait` (static dispatch, parameters), `dyn Trait` (dynamic dispatch, return types / struct fields).
  - **TypeScript**: generic type parameters `<T extends Interface>` (static), wide interface types (dynamic).
  - **Java**: bounded wildcards / type parameters (static), raw interface types (dynamic).
  - **Go**: `Interface` parameter types (static dispatch via implicit interface satisfaction).
  - **Swift**: `some Protocol` (opaque / static), `any Protocol` (existential / dynamic).
- **Pick the most specific abstract type for the capabilities needed.** Do not use a general collection type when you need ordered access — use an ordered-collection type (e.g., `Sequence` in Python, `Seq` in Scala) instead. Do not use a general collection type when set-membership speed (O(1) lookup) improves performance or when uniqueness semantics matter — use a set type instead. Choose the narrowest type that supports the operations actually required by the code.
- **Accept abstract, prefer abstract for returns.** In function signatures, use abstract types for parameters — the caller may pass any compatible value. Prefer abstract types for return values too, giving the implementation room to evolve. If a concrete return type provides meaningful guarantees beyond its abstract interface (e.g., construction-site results, serialization formats), a slightly more specific type is acceptable, but avoid over-committing to a concrete type that constrains future changes. Exceptions: protocols, abstract factories, and type-class instances may return abstract types.
- **CRITICAL: immutable by default in types.** Always reach for the immutable/read-only variant first — it is the default choice in every language. Use a mutable type only when you have a concrete, documented reason why immutability cannot work. This flips the default: instead of "use what matches behavior" (which tolerates mutable types for mutable values), the rule is "reach for immutable first; justify mutable exceptions."
  - TypeScript: use `readonly` on all interface/type properties; `readonly T[]` / readonly tuples over `T[]`; `ReadonlyMap<K,V>` / `ReadonlySet<T>` over mutable collections; `Readonly<T>` utility type; `as const` assertions.
  - Rust: prefer `let` over `let mut`; `&T` over `&mut T`; immutable struct fields; avoid `&mut self` when possible.
  - Python: `Sequence[T]` over `list`; `Mapping[K,V]` over `dict`; `frozenset` over `set`; `@dataclass(frozen=True)`; return copies over mutating inputs; `tuple` for fixed sequences.
  - Nix: values are inherently immutable — prefer pure `let ... in` expressions; avoid `let inherit;` patterns that obscure data flow; use `builtins.map`, `builtins.filter`, `builtins.foldl'` over iterative mutation.
  - Java: `List.of()`/`Set.of()`/`Map.of()`; `Collections.unmodifiable*`; `final` fields; records (Java 16+) for immutable data carriers.
  - C#: records with init-only properties; `readonly` structs; `IReadOnlyList<T>`, `IReadOnlyDictionary<K,V>`; `readonly` fields and members.
  - Swift: `let` over `var`; value types (structs) over classes by default; `struct` for data models (String/Array/Dictionary are already value types).
  - Kotlin: `val` over `var`; `listOf()` over `mutableListOf()`, same for map/set; use `List<T>`, `Map<K,V>`, `Set<T>` read-only interfaces.
  - PowerShell: `[Array]` is already fixed-size; prefer `[Collections.ObjectModel.ReadOnlyCollection[T]]` over mutable `[List[T]]`; avoid `[ref]` parameters; pipeline processing over iterative mutation.
  - Shell: `local` and `readonly` variable declarations; subshells for scoped state isolation; use `readonly` and `declare -r` for constants.
- **Prefer structural typing over nominal inheritance for interfaces.** Use protocols, interfaces, or type-classes to define type contracts based on the operations an object supports, rather than requiring a specific base class. Reserve class inheritance for implementation sharing, not interface definition.
- **Fully parameterize generic types.** Never leave generic types unparameterized (e.g., a bare `list` or `dict` in Python, a raw `List` or `Map` in Java, an unparameterized `array` in TypeScript, `Vec` in Rust, `ArrayList`/`Hashtable` in C#, `NSArray` in Swift, `List<*>` star projection in Kotlin). A bare generic discards all type information about elements, keys, values, and signatures — it is as vague as a catch-all type.
- **No catch-all types.** Never use catch-all types that bypass the type system: `any` (TypeScript), `Any` (Swift, Kotlin), `Object` (Java), `object` (Python, C#), `Box<dyn Any>` (Rust), or equivalents. `unknown` (TypeScript) is not a catch-all — it is sound and forces narrowing before use. Always find or define a precise type.

  **Handling untyped values from external boundaries.** When a catch-all type appears from an external/untyped source, use this decision hierarchy to handle it safely. Levels 1-2 are type narrowing (no justification needed); levels 3-4 are assertions (require inline justification).
  1. **Narrow to the known type** — when the shape/lifetime is known from context (documented API contract, validated schema, typed matcher). No justification needed.
  2. **Widen to an opaque/unknown type** — when no compile-time type info is available; treat as opaque until narrowed by runtime check. No justification needed.
  3. **Assert the type** — when runtime narrowing is infeasible but the type is verified by other means. Requires inline justification: why narrowing is insufficient and why the assertion is sound.
  4. **Assert through an opaque intermediate** — when structural type incompatibility prevents direct assertion. Requires justification: why the intermediate is needed.

  **Hard rule:** the escape hatch that skips all type checking is never acceptable (TypeScript `as any`, Python `typing.cast()` bypassing checks, Java unchecked casts, `unsafe` transmutes).

  ### TypeScript

  TypeScript-specific patterns following the general hierarchy above:
  1. **`: T / satisfies T as T`** — when the expected type is known from context (e.g., matcher value in a typed property).
  2. **`: unknown / satisfies unknown as unknown`** — when no compile-time type info is available. Prefer `: unknown` when a variable annotation is possible.
  3. **`as T`** — requires inline comment: why narrowing is insufficient and why the assertion is sound.
  4. **`as unknown as T`** — requires justification: why `as T` fails structurally and why the boundary is safe. **`as any` is never acceptable.**

  **`satisfies` identity rule:** `satisfies T as U` is only valid when `T` and `U` are the same type. If they differ, the `satisfies` constraint is meaningless — the `as` cast independently decides the result type.

  **Reference examples** (short forms):

  | Pattern                                  | Correct approach                                                   |
  | ---------------------------------------- | ------------------------------------------------------------------ |
  | Matcher in typed context                 | `expect.any(Number) satisfies number as number`                    |
  | Matcher, unknown inline                  | `expect.anything() satisfies unknown as unknown`                   |
  | Static import                            | `await import(\"./mod\") as typeof import(\"./mod\")`              |
  | Dynamic/no-d.ts import                   | Runtime validation: `typeof value.method === \"function\"`         |
  | Unparameterized `vi.fn()`                | `vi.fn<() => string>(() => \"test\")`                              |
  | Unparameterized matcher                  | `expect.objectContaining<Record<string, unknown>>({...})`          |
  | Callback param inference                 | `vi.fn((cb: (v: string) => unknown) => {...})`                     |
  | `Object.create(null)`                    | `... satisfies Record<string, unknown> as Record<string, unknown>` |
  | Discriminated union                      | Check `.type` first, then access `.value`                          |
  | Structurally incompatible                | `{} as unknown as WorkspaceLeaf`                                   |
  | Stdlib `any`, justification              | `as T` + inline comment why narrowing can't work                   |
  | Redundant cast after narrowing           | Omit assertion; add runtime shape check at boundary                |
  | Blind `as T` on stdlib `any`             | Use `: unknown` boundary, then narrow                              |
  | `path.join(cwd(), ...)` for local script | Use relative path — keeps import statically analyzable             |
  | Lint suppression for test idiom          | `// eslint-disable-next-line -- <why intentional>`                 |

  ### Other languages
  - **Rust**: `Box<dyn Any>` / `Box<dyn Error>` → `.downcast_ref::<T>()` (level 1/2); raw pointer cast `*const T as *const U` (level 3/4).
  - **Python**: `Any` from untyped boundary → `isinstance(x, T)` check (level 1/2); `cast(T, x)` with reason (level 3/4).
  - **Java**: `Object` → `instanceof` pattern match (level 1/2); unchecked `(T)` cast with reason (level 3/4).
  - **C#**: `object` / `dynamic` → `is` pattern match (level 1/2); `(T)` cast with reason (level 3/4).
  - **Swift**: `Any` / `AnyObject` → `as?` optional downcast (level 1/2); `as!` with reason (level 3/4).
  - **Kotlin**: `Any` → `is` smart cast (level 1/2); `as` with reason (level 3/4).

- **No type-error suppression.** Do not use `# type: ignore`, `@ts-ignore`, `@ts-expect-error`, `@SuppressWarnings`, `// NOLINT`, or similar suppression mechanisms. When intentionally bypassing the type system (e.g., testing with deliberately wrong types), use an explicit checked cast or conversion that produces a correctly-typed value.
- **No silent defaulting of missing values.** Do not substitute a default for a missing, failed, or errored value (`or ""`, `?? ""`, `|| ""`, `dict.get(k, "")`, `unwrap_or("")`, `except: pass`, swallowing `try/except`, `-ErrorAction SilentlyContinue` without a stated reason, `2>$null` without an annotation). Surface the failure or return the error so the caller decides. This is a value-masking fallback and is banned by the no-fallbacks rule in `core-behavior.instructions.md`.
- **No non-null assertions.** Do not use operators that assert non-null without runtime checking. These bypass strict null checks at the type level, making null-pointer errors possible at runtime. Instead, use proper type narrowing, early returns, or optional chaining to handle nullable values explicitly. Affected operators per language:
  - TypeScript: postfix `!`
  - Kotlin: `!!`
  - Swift: postfix `!` (force unwrapping)
  - Dart: postfix `!`
  - C#: postfix `!` (null-forgiving operator)
  - Rust: `.unwrap()` / `.expect()` on `Option` / `Result` (prefer `if let` / match / `?` operator instead)
- **`assert` is test-only.** Use `assert` only in test code. In production code, use proper error handling. The sole exception is runtime invariants whose violation must halt execution immediately.

## Related instruction files

- `programming-principles.instructions.md` — General coding principles including immutability-by-default, error handling, and architectural patterns.
- `core-behavior.instructions.md` — Immutable-by-default enforcement rules and agent-wide coding conventions.
