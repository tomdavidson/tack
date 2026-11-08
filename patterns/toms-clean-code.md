# Tom's Clean Code

Clean code that's readable, testable, and maintainable—built on strategic FP.

Good OOP requires mass pattern knowledge to avoid pitfalls. Strategic FP yields similar benefits—separation of concerns, testability, maintainability—with less ceremony: Go-like simplicity of plain data structures combined with Haskell/Erlang-inspired algebraic sum types, explicit error values, and first-class pure functions.

Pragmatic over dogmatic. The goal is **better code**, not paradigm or purity points.

## Universal Invariants

Every language guide splits rules into **Toolchain-Enforced** (backed by CI linters and typecheckers) and **Advisory** (architectural and review rules that remain advisory until a linter can enforce them). The invariants below hold in every language; the guides say how each is enforced.

Toolchain-enforced means zero warnings: linters and typecheckers run at their strictest setting and CI fails on any warning. A suppression is scoped to one construct and carries a reason. Code that confuses the analyzer is rewritten, not excused.

| Universal Invariant               | Meaning                                                                        |
| --------------------------------- | ------------------------------------------------------------------------------ |
| **Data ≠ Behavior (No OOP)**      | Plain data structures and free pure functions; no class hierarchies            |
| **Algebraic State (Sum Types)**   | Tagged unions / enums with exhaustive matching                                 |
| **Explicit Return & Param Types** | Every function signature declares its parameter and return types               |
| **Errors as Values**              | Explicit result types (`Result<T, E>`); no exceptions for domain failures      |
| **Zero Nested Branches in Loops** | Guard clauses and extracted pure helpers; max nesting depth 2                  |
| **Low Complexity**                | Shallow nesting, few branches and parameters; length is a smell, not the limit |

> **About examples:** Examples that illustrate structure (pipelines, guards, composition) may
> use placeholder names such as `u`, `x`, `f`, or `handle` and may omit type annotations.
> Examples that illustrate naming follow every naming rule.

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

Mutation is a problem only when it is observable outside the function. Building up an array
with `push` before returning it is fine; shared or cross-boundary mutation never is. When a
linter flags local mutation, suppress it at function scope with a one-line justification. When
mutation is chosen for performance, say so in that justification.

Give every binding the smallest possible scope: declare it at first use, and never reuse a
binding for a second meaning. Fewer places a value can change means fewer places to look when
it is wrong.

### Explicit Errors as Data

Errors are values, not exceptions. Return `Result<T, E>` or `Option<T>`.

```
findUser(id): Option<User>
parseConfig(raw): Result<Config, ParseError>
```

Exceptions for truly exceptional cases only. Business logic failures are expected—model them.

A `Result` is handled or discarded explicitly with a reason, never silently. Invariants a type
cannot express are checked where the value enters the domain and returned as a typed error,
never as an abort.

### No Nullable Absence

Use `Option<T>` (or explicit union narrowing) for values that may be absent. Domain logic never returns a nullable or sentinel value to mean "nothing".

### Composition Over Inheritance

Data + functions, no class hierarchies. Types define shape; functions transform.

```
type User = { id: string; name: string; isActive: boolean }
const deactivate = (u: User): User => ({ ...u, isActive: false })
const process = pipe(validate, enrich, format, save)
```

Classes only when forced by framework or library. Keep them thin, delegate to pure functions.

> **Adapters:** If a library or framework requires a class (e.g., an SDK base class or plugin
> interface), implement it in the Imperative Shell as an adapter. All business logic stays in
> pure functions outside the class.

### Higher-Order Functions

Functions that accept or return other functions.

```
const withLogging = (fn) => (input) => { log(input); return fn(input) }
users.filter(u => u.isActive)
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

Names are the primary documentation. If a name needs a comment to explain what it holds,
rename it. Call sites should read like sentences; data definitions should read like tables.

Casing and file naming follow each language's community convention; see the language guides
and [File Naming Convention](toms-clean-arch.md#file-naming-convention). Domain vocabulary
comes from the bounded context's [Ubiquitous Language](toms-clean-arch.md#ubiquitous-language).

#### Functions

- **Verb first**: name the action or the value returned (`validateUser`, `calculateTotal`)
- **Prefix vocabulary**: one meaning per prefix, used the same way everywhere

| Prefix                | Meaning                            | Returns                      |
| --------------------- | ---------------------------------- | ---------------------------- |
| `is`, `has`, `can`    | Predicate                          | Boolean                      |
| `to`                  | Infallible conversion              | Target type                  |
| `parse`               | Untrusted input to domain type     | `Result<T, ParseError>`      |
| `validate`            | Check a domain value against rules | `Result<T, ValidationError>` |
| `find`                | Lookup that may miss               | `Option<T>`                  |
| `get`                 | Lookup or access that cannot miss  | `T`                          |
| `calculate`, `derive` | Pure computation                   | `T`                          |
| `create`              | Construct a new value              | `T` or `Result<T, E>`        |
| `load`, `save`        | IO read or write; shell only       | `Result<T, E>`               |

- **Single responsibility**: if the honest name needs "and", split the function
- **No flag-driven names**: `renderSummary` and `renderDetail`, not `render(detailed)`

#### Types

- **Nouns** for data (`Customer`, `LineItem`); outcomes as `<Noun>Result` or `<Noun>Error`
- **Variants as qualified nouns**: `DraftOrder | SubmittedOrder`, not `Order1 | Order2`
- **Error variants say what happened**: `FileNotFound`, `CycleDetected`, not `GeneralError`
- **No type encodings**: no `IUser`, `UserType`, `nameString`, `salaryFloat`
- **No false types**: `accountList` must be a list; otherwise `accounts`
- **One tag key**: discriminated unions share a single tag key across the codebase; variant
  casing follows the language guide

#### Booleans

- **Positive predicates**: `isActive`, not `isNotInactive`
- **Read as a yes/no question**: `hasChildren`, `canRetry`; not `children`, `retry`
- **Union over boolean** when a third state is plausible

#### Variables and Constants

- **Scope-sized length**: variable names grow with scope. Single letters only for lambda
  parameters and loop variables in bodies of a few lines; exported or module-level names must
  be greppable. Functions and types invert this: wide-scope public entry points stay short and
  general (`parse`, `Order`); narrow private helpers carry the specific detail
  (`parseLineItemDiscount`).
- **Plural collections**: name collections with plural nouns (`accounts`, `activeUsers`), not
  singular nouns or container suffixes (`accountList`)
- **Units in names**: suffix physical and time quantities (`totalCents`, `lengthMm`,
  `timeoutMs`) unless a unit type carries the unit
- **Named constants**: no magic numbers or strings; `0`, `1`, `-1` and test fixtures excepted
- **Fixtures are named for what they are**: `thread`, `draftOrder`; variants carry the
  qualifier the test cares about (`expiredThread`, `orderWithTwoItems`); builders are
  `make<Type>(overrides)`. No `Fixture` suffix or type encoding. Scope-sized length applies in
  tests too; single letters are not fixtures.
- **No shadowing**: an inner scope never reuses an outer name
- **Unused bindings**: mark them per the language convention (commonly a `_` prefix)

#### Vocabulary

- **No abbreviations**: `customer` not `cust`, `transaction` not `txn`. Allowed: universal
  acronyms (`id`, `url`, `http`) and terms established in the ubiquitous language.
- **Acronym casing is fixed per language**: each language guide names exactly one form
  (`HttpClient` or `HTTPClient`, `userId` or `userID`) and the linter enforces it. The author
  never chooses; a codebase never has both.
- **Pronounceable**: `generationTimestamp`, not `genymdhms`
- **One word per concept**: pick `get`, `fetch`, or `retrieve` and use only that one
- **One concept per word**: don't use `add` for both arithmetic and insertion
- **No noise words**: `Info`, `Data`, `Object`, `Manager`, `Helper`, `Util` distinguish nothing;
  `ProductInfo` beside `ProductData` is a naming failure
- **No cute names**: `deleteAllItems`, not `whack`
- **Meaningful distinctions**: when two names differ, the difference says why
  (`sourceSheet` and `targetSheet`, not `sheet` and `sheet2`; `findAccountById` and
  `listActiveAccounts`, not `getActiveAccount` and `getActiveAccounts`)

#### Domain and Context

- **Core speaks the problem domain**: domain and application code use the business vocabulary
  from specs and ADRs
- **Shell speaks the solution domain**: adapters may use technical names (`Queue`, `Cache`,
  `Gateway`)
- **Context from structure, not prefixes**: the module or type supplies context
  (`address.state`). Prefix (`addressState`) only when a name leaves its context, such as a
  flat export or an environment variable.
- **Framework-forced classes** (see Adapters above) carry a role suffix naming what they adapt
  (`Adapter`, `Client`, `Gateway`); each language guide lists its allowed suffixes
- **Foreign names are data**: identifiers we do not own (wire headers, query params, vendor
  payload keys, protocol fields such as `Thread-ID` or `Authorization`) are string values or
  entries in a boundary schema, never declared names in our code. Naming rules govern the names
  we choose; a lint suppression to admit someone else's name is a review reject.
- **External shapes are translated, not mirrored**: describe an external payload with a schema
  at the boundary and map it to domain vocabulary where it enters; the raw external shape never
  crosses into application or domain code. Never hand-write a type that copies a payload field
  for field. This is the naming face of the anti-corruption layer in
  [Tom's Clean Architecture](toms-clean-arch.md). Each language guide names the file type that
  holds the translation and the schema tool that does it.

### Function Shape

- **Explicit types**: Always annotate parameter and return types on functions.
- **One idea**: low cognitive complexity, nesting ≤ 2, no branches in loop bodies (language
  guides set the ceilings). Split when the name or a test needs "and", not to satisfy a line
  count. Do not scatter a linear narrative into once-called helpers.
- **Fits on a screen**: more than 60 logical lines is an error (one screen at a readable font;
  blank lines and comments excluded). Aim for what stays visible beside a test panel, about 30.
  Length only approximates what matters, which is scope and branching.
- **Multi-param default**: 2-3 params of same kind is fine (`add(a, b)`, `clamp(min, max, value)`)
- **Curry when composed**: Don't pre-curry; curry at point of use if piping needed
- **Curried for deps**: `(config) => (data) => result` when deps stable, data varies, function reused
- **Data object**: 4+ params, or mixed concerns for self-documenting calls
- **No boolean parameters**: a flag that switches behavior becomes a 2-variant union/enum or two
  functions (see Naming: no flag-driven names)

### Comments

- **Why, not what**: Code shows what; comments explain why
- **No dead comments**: Delete, don't comment out. VCS remembers.
- **Acceptable**: Legal notices, regex explanations, TODOs with ticket refs

### Structure

- **Vertical**: Related code close together, blank lines separate concepts
- **Horizontal**: 100-110 char lines max (formatter-enforced)
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
if (!user) return Err(UserMissing)
if (!user.isActive) return Err(UserInactive)
return Ok(process(user))
```

Max nesting depth: 2. Never nest `if`/`match`/`switch` branches inside control loops; extract a named pure function for the element transform.

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
users.filter(u => u.isActive).map(u => u.email)
```

`for` acceptable for performance-critical paths or when early-return error propagation is clearer, provided the loop body contains no nested branching.

Iteration over a finite collection is bounded by construction. Anything else (`while`, retry, polling, recursion whose depth depends on input) carries an explicit cap and returns a typed error when the cap is hit. Recursion over a finite structure is fine; unbounded recursion is not.

## Standing Rules

| Rule         | Meaning                                                                            |
| ------------ | ---------------------------------------------------------------------------------- |
| Boy Scout    | Leave code cleaner than you found it                                               |
| KISS         | Reduce complexity wherever possible                                                |
| DRY          | Single source of truth—extract when duplicated                                     |
| Root Cause   | Fix sources, not symptoms                                                          |
| Consistency  | Follow existing conventions in codebase                                            |
| When in Rome | Follow community/framework surface standards; apply Strategic FP between the lines |

**When in Rome:** Community standards take precedence for surface conventions: formatting, docblocks, file and type layout, naming, and public framework APIs. Apply Strategic FP between the lines: small pure functions, explicit error values, flat control flow, and immutable domain data. Keep framework-required OOP at the edges as thin adapters that delegate to pure logic. Each language or framework guide names its governing standard.

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
- [ ] No nullable absence; Option or union narrowing
- [ ] No shared mutable state
- [ ] Max nesting depth 2; no branches inside loop bodies
- [ ] No class hierarchies
- [ ] No DI containers
- [ ] States as discriminated unions / sum types
- [ ] One idea per function; low cognitive complexity; fits on a screen
- [ ] Loops and recursion bounded; caps return typed errors
- [ ] Zero lint warnings; suppressions scoped with a reason
- [ ] Descriptive, scope-sized names; no abbreviations or noise words
- [ ] Comments explain why, not what
- [ ] Readable without FP expertise
