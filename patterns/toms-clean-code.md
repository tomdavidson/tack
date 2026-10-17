# Tom's Clean Code

Clean code that's readable, testable, and maintainable—built on strategic FP.

Good OOP requires mass pattern knowledge to avoid pitfalls. Strategic FP yields similar benefits—separation of concerns, testability, maintainability—with less ceremony: Go-like simplicity of plain data structures combined with Haskell/Erlang-inspired algebraic sum types, explicit error values, and first-class pure functions.

Pragmatic over dogmatic. The goal is **better code**, not paradigm or purity points.

## Language Guides & Enforcement Rule

Every language guide splits rules into **Toolchain-Enforced** (backed by CI linters and typecheckers) and **Advisory** (architectural and review rules that remain advisory until a linter can enforce them):

- [TypeScript](lang-typescript.md) (`oxlint` + `@tack/eslint-config` + `tsc`)
- [Rust](lang-rust.md) (`clippy` + `.clippy.toml` + `rustfmt`)
- [Python](lang-python.md) (`ruff` + `basedpyright`)
- [PHP](lang-php.md) (`phpcs` + `SlevomatCodingStandard` + `phpstan`)

| Universal Invariant               | TypeScript                           | Rust                                  | Python                                        | PHP                                        |
| --------------------------------- | ------------------------------------ | ------------------------------------- | --------------------------------------------- | ------------------------------------------ |
| **Data ≠ Behavior (No OOP)**      | `type` + plain objects + arrow fns   | `struct`/`enum` + free pure functions | `@dataclass(frozen=True, slots=True)` + fns   | Readonly DTOs/VOs + pure service functions |
| **Algebraic State (Sum Types)**   | Discriminated unions + `switch`      | `enum` + exhaustive `match`           | Union types + `match`/`case` + `assert_never` | Backed enums / sealed unions (`phpstan`)   |
| **Explicit Return & Param Types** | `explicit-function-return-type: err` | Compiler-enforced on every `fn`       | `ANN` (`ruff`) + `basedpyright`               | `declare(strict_types=1)` + `phpstan` L6+  |
| **Errors as Values**              | `neverthrow` `Result<T, E>`          | `Result<T, E>` + `thiserror` + `?`    | Union `T \| DomainError` (`Result[T, E]`)     | Domain result/VO returns; catch at edges   |
| **Zero Nested Branches in Loops** | `max-depth: 2`, `no-else-return`     | `excessive-nesting = 2`, `let else`   | `max-nested-blocks = 2` (`PLR1702`), `RET`    | Guard clauses + extracted pure helpers     |
| **Small Functions & Signatures**  | ≤ 25 lines, ≤ 3 params, no bool flag | ≤ 30 lines, ≤ 4 params, ≤ 1 bool      | ≤ 30 stmts, ≤ 4 params, no bool flag (`FBT`)  | Small methods, command/options DTOs        |

## Core Principles

### Pure Functions First

Functions without side effects, producing the same output for the same input.

```
calculateTotal(order) → Money       // pure: just math
saveOrder(order) → Result<void>     // impure: side effect (DB)
```

Default to pure for business logic. Impurity is allowed—isolate it at boundaries.

**Async ≠ impure.** Impurity comes from IO (network, disk, database, randomness, time)—not from async syntax.

### Immutability by Default

Don't mutate; create new.

```
const updated = { ...user, name: "New" }
```

Mutate when performance demands it. Comment why.

> **Locally scoped mutation is fine.** Mutation is only a problem when it is observable outside
> the function. Building up an array with `push` before returning it is acceptable. Lint rules
> that flag local mutation (`no-param-reassign`, `functional/no-let`) can be disabled at the
> function scope with a brief comment. Shared or cross-boundary mutation is never acceptable.

### Explicit Errors as Data

Errors are values, not exceptions. Return `Result<T, E>` or `Option<T>`.

```
findUser(id): Option<User>
parseConfig(raw): Result<Config, ParseError>
```

Exceptions for truly exceptional cases only. Business logic failures are expected—model them.

### No Nulls

Use `Option<T>` (or explicit union narrowing) for values that may be absent. No ambiguous `null` returns from domain logic.

### Composition Over Inheritance

Data + functions, no class hierarchies. Types define shape; functions transform.

```
type User = { id: string; name: string; active: boolean }
const deactivate = (u: User): User => ({ ...u, active: false })
const process = pipe(validate, enrich, format, save)
```

Classes only when forced by framework or library. Keep them thin, delegate to pure functions.

> **Adapters:** If a library requires a class (e.g., an SDK base class or Drupal plugin),
> implement it in the Imperative Shell as an adapter. All business logic stays in pure functions
> outside the class.

### Higher-Order Functions

Functions that accept or return other functions.

```
const withLogging = (fn) => (input) => { log(input); return fn(input) }
users.filter(u => u.active)
```

Use for: reusable wrappers, callbacks, collection transforms. Avoid: over-abstraction.

### Model State as Discriminated Unions

Tagged sum types, not boolean flags or optional fields.

```
type Request =
  | { status: "idle" }
  | { status: "loading" }
  | { status: "success"; data: Data }
  | { status: "error"; error: Error }
```

Compiler/typechecker enforces exhaustive handling. Invalid states become unrepresentable.

### Functional Core, Imperative Shell

Separate pure logic from IO. See [Tom's Clean Architecture](toms-clean-arch.md) for the full layered structure and boundary rules.

- **Core**: Pure functions, domain types, business rules. Zero IO.
- **Shell**: Thin adapters for HTTP, DB, filesystem, queues.

### No DI Containers

Pass dependencies as function parameters or use simple factory functions. See [Tom's Clean Architecture](toms-clean-arch.md) for composition root wiring.

## Code Hygiene

### Naming

- **Functions**: Verbs describing action or return value (`validateUser`, `calculateTotal`)
- **Types**: Nouns (`User`, `ValidationResult`)
- **Booleans**: Positive predicates (`isActive` not `isNotInactive`)
- **No abbreviations**: `customer` not `cust`, `transaction` not `txn`
- **Searchable**: No single letters, no magic numbers
- **One word per concept**: Pick `get`, `fetch`, or `retrieve`—not all three

### Functions

- **Explicit types**: Always annotate parameter and return types on functions across all languages.
- **Small**: 5-25 lines max (30 in Rust/Python). Flat, branchless functional pipelines (e.g. `ResultAsync` chains)
  may exceed this if the length is due to formatting, not cyclomatic complexity. In those cases,
  disable the line-count lint scoped to the function block and add a comment explaining why.
- **Single responsibility**: Does one thing, named for that thing
- **Multi-param default**: 2-3 params of same kind is fine (`add(a, b)`, `clamp(min, max, val)`)
- **Curry when composed**: Don't pre-curry; curry at point of use if piping needed
- **Curried for deps**: `(config) => (data) => result` when deps stable, data varies, function reused
- **Data object**: 4+ params, or mixed concerns for self-documenting calls
- **No flag arguments**: Never pass boolean flags to switch behavior; use a 2-variant union/enum or split into two functions

### Comments

- **Why, not what**: Code shows what; comments explain why
- **No dead comments**: Delete, don't comment out. VCS remembers.
- **Acceptable**: Legal notices, regex explanations, TODOs with ticket refs

### Structure

- **Vertical**: Related code close together, blank lines separate concepts
- **Horizontal**: 100-110 char lines max (enforced by `dprint`)
- **Downward**: Top-to-bottom narrative; caller above callee

## Practical Patterns

### Railway-Oriented Flow

Success and error as parallel tracks. Errors short-circuit.

```
validate(input)
  .andThen(enrich)
  .andThen(save)
  .mapErr(logError)
```

### Guard Clauses Over Nesting (Zero Nested Loop Branches)

```
if (!user) return Err("missing user")
if (!user.active) return Err("inactive")
return Ok(process(user))
```

Max nesting depth: 1-2 levels. Never nest `if`/`match`/`switch` branches inside control loops; extract a named pure function for the element transform.

### Lookup Tables Over Switch

```
const handlers = {
  pending: handlePending,
  processing: handleProcessing,
  complete: handleComplete,
} as const

const handle = (status: Status) => handlers[status]()
```

### Declarative Iteration

```
users.filter(u => u.active).map(u => u.email)
```

`for` acceptable for performance-critical paths or when early-return error propagation (`?`) is clearer, provided the loop body contains no nested branching.

## Standing Rules

| Rule         | Meaning                                                                            |
| ------------ | ---------------------------------------------------------------------------------- |
| Boy Scout    | Leave code cleaner than you found it                                               |
| KISS         | Reduce complexity wherever possible                                                |
| DRY          | Single source of truth—extract when duplicated                                     |
| Root Cause   | Fix sources, not symptoms                                                          |
| Consistency  | Follow existing conventions in codebase                                            |
| When in Rome | Follow community/framework surface standards; apply Strategic FP between the lines |

**When in Rome:** Community standards take precedence for surface conventions—formatting, docblocks, file/class layout, naming, and public framework APIs. Drupal modules published on drupal.org follow `drupal/coder`'s `Drupal` + `DrupalPractice` standards. Apply Strategic FP in the space between the lines: small pure functions, explicit error values, flat control flow, and immutable domain data. Keep framework-required OOP at the edges as thin export/adapter interfaces that delegate to pure logic. Omit redundant documentation only where the community standard explicitly permits it.

## When to Break Rules

| Situation                       | Pragmatic Choice                       |
| ------------------------------- | -------------------------------------- |
| Framework requires class        | Thin shell, delegate to pure functions |
| Mutation is 10x faster          | Mutate locally, document why           |
| Error handling adds noise       | Skip Result for infallible ops         |
| Deep pipeline hurts readability | Break into named steps                 |

The goal is **better code**, not points.

## Checklist

- [ ] Pure functions for business logic
- [ ] Explicit parameter and return types on all functions
- [ ] Side effects at edges only
- [ ] Errors as values (Result/Option/union)
- [ ] No nulls—Option or union narrowing for absence
- [ ] No shared mutable state
- [ ] Zero nested conditionals inside loops (max depth 2)
- [ ] No class hierarchies
- [ ] No DI containers
- [ ] States as discriminated unions / sum types
- [ ] Functions 5-25 lines (≤ 30 in Rust/Python)
- [ ] Descriptive names, no abbreviations
- [ ] Comments explain why, not what
- [ ] Readable without FP expertise
